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

    static final class Local {
        int id;
        boolean audio, video, back, videoOn = true;
        Surface encoder;
        CameraDevice camera;
        CameraCaptureSession session;
        boolean reported;
    }

    static final class VideoView {
        int viewId, stream;
        boolean mirror, cover;
        TextureView view;
        Surface surface;
        /** Picture size as delivered (before rotation) and its rotation. */
        int width, height, rotation;
    }

    static final HashMap<Integer, Local> locals = new HashMap<>();
    static final SparseArray<VideoView> videos = new SparseArray<>();
    static final ArrayList<Local> waitingPermission = new ArrayList<>();
    /** Remote stream sizes as the decoders reported them: {width, height, rotation}. */
    static final HashMap<Integer, int[]> remoteSizes = new HashMap<>();
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
            b.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, new Range<>(15, 30));
            l.session.setRepeatingRequest(b.build(), null, camera);
        } catch (Exception ignored) {
        }
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
        transform(v);
    }

    static boolean isRemote(int stream) {
        return stream < 0; // ids from 0x80000000 up are negative as Java ints
    }

    static void attach(VideoView v) {
        if (v.surface == null || v.stream == 0) return;
        if (isRemote(v.stream)) {
            int[] size = remoteSizes.get(v.stream);
            if (size != null) {
                v.width = size[0];
                v.height = size[1];
                v.rotation = size[2];
            }
            nativeRemoteSurface(v.stream, v.surface);
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
            if (v.surface != null) nativeRemoteSurface(v.stream, null);
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

    /** Fits (or, with cover, fills) the picture into the view, turned and mirrored. */
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
