package com.wufour.zui;

import android.Manifest;
import android.content.Context;
import android.content.pm.PackageManager;
import android.graphics.Matrix;
import android.graphics.SurfaceTexture;
import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraDevice;
import android.hardware.camera2.CameraManager;
import android.hardware.camera2.CaptureRequest;
import android.media.AudioManager;
import android.os.Handler;
import android.os.HandlerThread;
import android.util.Range;
import android.util.SparseArray;
import android.view.Surface;
import android.view.TextureView;
import android.view.View;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Calls on Android, the parts that need the framework: microphone and camera permissions, the
 * call audio mode, the camera (Camera2, writing into the H.264 encoder's input surface and into
 * preview views), and the video views (TextureViews: the camera preview, or a decoder's output).
 * Encoding, decoding and sound are in Zig (zui/media/android.zig, NDK MediaCodec and AAudio).
 */
final class ZuiMedia {
    static final int READY = 1, FAILED = 2, ENDED = 3;
    static final int PERMISSION_REQUEST = 7101;
    /** The size the camera captures and the encoder is configured for. */
    static final int WIDTH = 640, HEIGHT = 480;

    // Implemented in Zig (zui/media/android.zig).
    static native void nativeResult(int id, int kind, String reason);
    /** Degrees clockwise the receiver turns our camera's picture (video orientation). */
    static native void nativeRotation(int id, int degrees);
    /** The surface a remote stream's decoder draws into, or null when its view went away. */
    static native void nativeRemoteSurface(int stream, Surface surface);
    /** The camera writes into the encoder surface that swapEncoder handed over. */
    static native void nativeEncoderSwapped(int id);

    static final class Local {
        int id;
        boolean audio, video, back, videoOn = true;
        Surface encoder;
        CameraDevice camera;
        CameraCaptureSession session;
        boolean reported;
        /** What the camera offers for encoders, and its framerate ranges. */
        volatile android.util.Size[] sizes;
        Range<Integer>[] fpsRanges;
        int fps = 30;
        boolean swapPending;
    }

    static final class VideoView {
        int viewId, stream;
        boolean mirror, cover;
        TextureView view;
        Surface surface;
        /** Picture size as delivered (before rotation) and its rotation. */
        int width, height, rotation;
    }

    /** Read from the encoder thread too (pickSize). */
    static final java.util.concurrent.ConcurrentHashMap<Integer, Local> locals = new java.util.concurrent.ConcurrentHashMap<>();
    static final SparseArray<VideoView> videos = new SparseArray<>();
    static final ArrayList<Local> waitingPermission = new ArrayList<>();
    /** Remote stream sizes as the decoders reported them: {width, height, rotation}. */
    static final HashMap<Integer, int[]> remoteSizes = new HashMap<>();
    /** One GL renderer per remote stream: its decoder draws once, the renderer into every view. */
    static final HashMap<Integer, ZuiStreamRenderer> renderers = new HashMap<>();
    static HandlerThread cameraThread;
    static Handler camera;
    static int audioUsers;
    static final AtomicBoolean wakePending = new AtomicBoolean();

    // ---- from Zig, UI thread ----

    static void open(int id, boolean audio, boolean video, boolean back, Surface encoder) {
        Local l = new Local();
        l.id = id;
        l.audio = audio;
        l.video = video;
        l.back = back;
        l.encoder = encoder;
        locals.put(id, l);
        ArrayList<String> need = new ArrayList<>();
        if (audio && Zui.activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) need.add(Manifest.permission.RECORD_AUDIO);
        if (video && Zui.activity.checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) need.add(Manifest.permission.CAMERA);
        if (need.isEmpty()) {
            start(l);
            return;
        }
        waitingPermission.add(l);
        Zui.activity.requestPermissions(need.toArray(new String[0]), PERMISSION_REQUEST);
    }

    static void permissionResult(String[] permissions, int[] results) {
        boolean granted = results.length > 0;
        for (int r : results) granted &= r == PackageManager.PERMISSION_GRANTED;
        ArrayList<Local> waiting = new ArrayList<>(waitingPermission);
        waitingPermission.clear();
        for (Local l : waiting) {
            if (locals.get(l.id) != l) continue;
            if (granted) start(l);
            else fail(l, "denied");
        }
    }

    static void start(Local l) {
        if (l.audio) audioMode(true);
        if (!l.video) {
            report(l);
            return;
        }
        openCamera(l);
    }

    static void report(Local l) {
        if (l.reported) return;
        l.reported = true;
        nativeResult(l.id, READY, "");
    }

    static void fail(Local l, String reason) {
        locals.remove(l.id);
        if (l.audio && l.reported) audioMode(false);
        closeCamera(l);
        nativeResult(l.id, l.reported ? ENDED : FAILED, reason);
    }

    static void close(int id) {
        Local l = locals.remove(id);
        if (l == null) return;
        closeCamera(l);
        if (l.audio && l.reported) audioMode(false);
    }

    static void enable(int id, boolean audio, boolean video) {
        Local l = locals.get(id);
        if (l == null || !l.video || l.videoOn == video) return;
        l.videoOn = video;
        // A muted camera stops capturing; the other side keeps the last picture.
        if (video) repeat(l);
        else if (l.session != null) {
            try {
                l.session.stopRepeating();
            } catch (Exception ignored) {
            }
        }
    }

    static void switchCamera(int id) {
        Local l = locals.get(id);
        if (l == null || !l.video) return;
        closeCamera(l);
        l.back = !l.back;
        openCamera(l);
    }

    /** The phone's call audio: echo cancellation, and the loudspeaker for video calls. */
    static void audioMode(boolean on) {
        audioUsers += on ? 1 : -1;
        AudioManager am = (AudioManager) Zui.activity.getSystemService(Context.AUDIO_SERVICE);
        if (on && audioUsers == 1) {
            am.setMode(AudioManager.MODE_IN_COMMUNICATION);
            am.setSpeakerphoneOn(true);
        } else if (!on && audioUsers <= 0) {
            audioUsers = 0;
            am.setSpeakerphoneOn(false);
            am.setMode(AudioManager.MODE_NORMAL);
        }
    }

    // ---- camera ----

    static void openCamera(Local l) {
        if (cameraThread == null) {
            cameraThread = new HandlerThread("zui-camera");
            cameraThread.start();
            camera = new Handler(cameraThread.getLooper());
        }
        CameraManager cm = (CameraManager) Zui.activity.getSystemService(Context.CAMERA_SERVICE);
        try {
            String chosen = null;
            int sensor = 0;
            for (String cid : cm.getCameraIdList()) {
                CameraCharacteristics c = cm.getCameraCharacteristics(cid);
                Integer facing = c.get(CameraCharacteristics.LENS_FACING);
                if (facing == null) continue;
                boolean isBack = facing == CameraCharacteristics.LENS_FACING_BACK;
                if (isBack == l.back) {
                    chosen = cid;
                    android.hardware.camera2.params.StreamConfigurationMap map = c.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
                    if (map != null) l.sizes = map.getOutputSizes(android.media.MediaCodec.class);
                    l.fpsRanges = c.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES);
                    Integer o = c.get(CameraCharacteristics.SENSOR_ORIENTATION);
                    sensor = o == null ? 0 : o;
                    break;
                }
            }
            if (chosen == null) {
                fail(l, "unavailable");
                return;
            }
            int display = Zui.activity.getWindowManager().getDefaultDisplay().getRotation() * 90;
            int rotation = l.back ? (sensor - display + 360) % 360 : (sensor + display) % 360;
            nativeRotation(l.id, rotation);
            cm.openCamera(chosen, new CameraDevice.StateCallback() {
                @Override
                public void onOpened(CameraDevice d) {
                    Zui.main.post(() -> {
                        if (locals.get(l.id) != l) {
                            d.close();
                            return;
                        }
                        l.camera = d;
                        session(l);
                    });
                }

                @Override
                public void onDisconnected(CameraDevice d) {
                    d.close();
                    Zui.main.post(() -> {
                        if (l.camera == d) l.camera = null;
                    });
                }

                @Override
                public void onError(CameraDevice d, int error) {
                    d.close();
                    Zui.main.post(() -> {
                        if (locals.get(l.id) == l) fail(l, "unavailable");
                    });
                }
            }, camera);
        } catch (SecurityException e) {
            fail(l, "denied");
        } catch (Exception e) {
            fail(l, "unavailable");
        }
    }

    static void closeCamera(Local l) {
        if (l.session != null) {
            try {
                l.session.close();
            } catch (Exception ignored) {
            }
            l.session = null;
        }
        if (l.camera != null) {
            l.camera.close();
            l.camera = null;
        }
    }

    /** The camera's outputs: the encoder plus every preview view showing this stream. */
    static ArrayList<Surface> targets(Local l) {
        ArrayList<Surface> out = new ArrayList<>();
        if (l.encoder != null) out.add(l.encoder);
        for (int i = 0; i < videos.size(); i++) {
            VideoView v = videos.valueAt(i);
            if (v.stream == l.id && v.surface != null) out.add(v.surface);
        }
        return out;
    }

    static void session(Local l) {
        if (l.camera == null) return;
        if (l.session != null) {
            try {
                l.session.close();
            } catch (Exception ignored) {
            }
            l.session = null;
        }
        ArrayList<Surface> out = targets(l);
        if (out.isEmpty()) return;
        try {
            l.camera.createCaptureSession(out, new CameraCaptureSession.StateCallback() {
                @Override
                public void onConfigured(CameraCaptureSession s) {
                    Zui.main.post(() -> {
                        if (l.camera == null || locals.get(l.id) != l) {
                            s.close();
                            return;
                        }
                        l.session = s;
                        if (l.videoOn) repeat(l);
                        report(l);
                        if (l.swapPending) {
                            l.swapPending = false;
                            nativeEncoderSwapped(l.id);
                        }
                    });
                }

                @Override
                public void onConfigureFailed(CameraCaptureSession s) {
                    Zui.main.post(() -> {
                        if (locals.get(l.id) == l && !l.reported) fail(l, "unavailable");
                    });
                }
            }, camera);
        } catch (Exception e) {
            if (!l.reported) fail(l, "unavailable");
        }
    }

    static void repeat(Local l) {
        if (l.session == null || l.camera == null) return;
        try {
            CaptureRequest.Builder b = l.camera.createCaptureRequest(CameraDevice.TEMPLATE_RECORD);
            for (Surface s : targets(l)) b.addTarget(s);
            b.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, fpsRange(l));
            l.session.setRepeatingRequest(b.build(), null, camera);
        } catch (Exception ignored) {
        }
    }

    /** The camera framerate range closest to l.fps from below, as wide as possible. */
    static Range<Integer> fpsRange(Local l) {
        Range<Integer> best = null;
        if (l.fpsRanges != null) for (Range<Integer> r : l.fpsRanges) {
            if (r.getUpper() > l.fps) continue;
            if (best == null || r.getUpper() > best.getUpper() || (r.getUpper().equals(best.getUpper()) && r.getLower() < best.getLower())) best = r;
        }
        return best != null ? best : new Range<>(15, 30);
    }

    /** From the encoder thread: the largest camera size within w x h (4:3 first), as w << 32 | h. */
    static long pickSize(int id, int w, int h) {
        Local l = locals.get(id);
        android.util.Size[] sizes = l == null ? null : l.sizes;
        if (sizes == null) return ((long) w << 32) | h;
        android.util.Size best = null;
        for (int pass = 0; pass < 2 && best == null; pass++) {
            for (android.util.Size s : sizes) {
                if (s.getWidth() > w || s.getHeight() > h) continue;
                if (pass == 0 && s.getWidth() * 3 != s.getHeight() * 4) continue;
                if (best == null || s.getWidth() * s.getHeight() > best.getWidth() * best.getHeight()) best = s;
            }
        }
        if (best == null) return ((long) WIDTH << 32) | HEIGHT;
        return ((long) best.getWidth() << 32) | best.getHeight();
    }

    /** From the encoder thread: a new encoder surface (another size or framerate) for the camera. */
    static void swapEncoder(int id, Surface encoder, int fps) {
        Zui.main.post(() -> {
            Local l = locals.get(id);
            if (l == null) return;
            l.encoder = encoder;
            l.fps = fps;
            l.swapPending = true;
            session(l);
        });
    }

    // ---- video views ----

    static View createView(int viewId) {
        VideoView v = new VideoView();
        v.viewId = viewId;
        v.view = new TextureView(Zui.activity);
        v.view.setOpaque(false);
        v.view.setSurfaceTextureListener(new TextureView.SurfaceTextureListener() {
            @Override
            public void onSurfaceTextureAvailable(SurfaceTexture st, int w, int h) {
                st.setDefaultBufferSize(WIDTH, HEIGHT);
                v.surface = new Surface(st);
                attach(v);
                transform(v);
            }

            @Override
            public void onSurfaceTextureSizeChanged(SurfaceTexture st, int w, int h) {
                transform(v);
            }

            @Override
            public boolean onSurfaceTextureDestroyed(SurfaceTexture st) {
                detach(v);
                if (v.surface != null) v.surface.release();
                v.surface = null;
                return true;
            }

            @Override
            public void onSurfaceTextureUpdated(SurfaceTexture st) {}
        });
        videos.put(viewId, v);
        return v.view;
    }

    static void destroyView(int viewId) {
        VideoView v = videos.get(viewId);
        if (v == null) return;
        detach(v);
        videos.remove(viewId);
    }

    static void video(int viewId, int stream, boolean mirror, boolean cover) {
        VideoView v = videos.get(viewId);
        if (v == null) return;
        if (v.stream != stream) {
            detach(v);
            v.stream = stream;
            attach(v);
        }
        v.mirror = mirror;
        v.cover = cover;
        if (isRemote(stream)) {
            ZuiStreamRenderer r = renderers.get(stream);
            if (r != null && v.surface != null) r.attach(v.view.getSurfaceTexture(), mirror, cover);
        } else transform(v);
    }

    static boolean isRemote(int stream) {
        return stream < 0; // ids from 0x80000000 up are negative as Java ints
    }

    static void attach(VideoView v) {
        if (v.surface == null || v.stream == 0) return;
        if (isRemote(v.stream)) {
            ZuiStreamRenderer r = renderers.get(v.stream);
            if (r == null) {
                r = new ZuiStreamRenderer();
                synchronized (renderers) {
                    renderers.put(v.stream, r);
                }
                int[] size = remoteSizes.get(v.stream);
                if (size != null) {
                    r.width = size[0];
                    r.height = size[1];
                    r.rotation = size[2];
                }
                nativeRemoteSurface(v.stream, r.surface);
            }
            v.view.setTransform(null);
            r.attach(v.view.getSurfaceTexture(), v.mirror, v.cover);
        } else {
            Local l = locals.get(v.stream);
            // The camera writes in its sensor's orientation; TextureView shows it upright.
            v.width = HEIGHT;
            v.height = WIDTH;
            v.rotation = 0;
            if (l != null) session(l);
        }
    }

    static void detach(VideoView v) {
        if (v.stream == 0) return;
        if (isRemote(v.stream)) {
            ZuiStreamRenderer r = renderers.get(v.stream);
            if (r != null && v.view.getSurfaceTexture() != null) r.detach(v.view.getSurfaceTexture());
        } else {
            Local l = locals.get(v.stream);
            int s = v.stream;
            v.stream = 0;
            if (l != null) session(l);
            v.stream = s;
        }
    }

    /** From a decoder thread: a remote stream's picture size and rotation. */
    static void remoteSize(int stream, int w, int h, int rotation) {
        ZuiStreamRenderer renderer;
        synchronized (renderers) {
            renderer = renderers.get(stream);
        }
        if (renderer != null) {
            renderer.width = w;
            renderer.height = h;
            renderer.rotation = rotation;
            renderer.refresh();
        }
        Zui.main.post(() -> {
            remoteSizes.put(stream, new int[] {w, h, rotation});
            for (int i = 0; i < videos.size(); i++) {
                VideoView v = videos.valueAt(i);
                if (v.stream != stream) continue;
                v.width = w;
                v.height = h;
                v.rotation = rotation;
                transform(v);
            }
        });
    }

    /** From native: a remote stream ended; its renderer goes. */
    static void remoteClosed(int stream) {
        Zui.main.post(() -> {
            remoteSizes.remove(stream);
            ZuiStreamRenderer r;
            synchronized (renderers) {
                r = renderers.remove(stream);
            }
            if (r != null) r.release();
        });
    }

    /** Fits (or, with cover, fills) the camera preview into the view, mirrored if asked. */
    static void transform(VideoView v) {
        float vw = v.view.getWidth(), vh = v.view.getHeight();
        if (vw <= 0 || vh <= 0 || v.width <= 0 || v.height <= 0) return;
        boolean sideways = v.rotation % 180 != 0;
        float dw = sideways ? v.height : v.width, dh = sideways ? v.width : v.height;
        float s = v.cover ? Math.max(vw / dw, vh / dh) : Math.min(vw / dw, vh / dh);
        Matrix m = new Matrix();
        m.setTranslate(-vw / 2, -vh / 2);
        // TextureView stretches the buffer over the view; undo that, then size, turn and flip.
        m.postScale(v.width * s / vw, v.height * s / vh);
        m.postRotate(v.rotation);
        if (v.mirror) m.postScale(-1, 1);
        m.postTranslate(vw / 2, vh / 2);
        v.view.setTransform(m);
        v.view.invalidate();
    }

    // ---- any thread ----

    /** Calls events are waiting for the UI thread (zui/calls.zig). */
    static void wake() {
        if (!wakePending.compareAndSet(false, true)) return;
        Zui.main.post(() -> {
            wakePending.set(false);
            if (Zui.started) Zui.nativeCallsPump();
        });
    }
}
