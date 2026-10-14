package com.wufour.zui;

import android.Manifest;
import android.content.Context;
import android.content.pm.PackageManager;
import android.graphics.ImageFormat;
import android.graphics.Matrix;
import android.graphics.SurfaceTexture;
import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraDevice;
import android.hardware.camera2.CameraManager;
import android.hardware.camera2.CaptureRequest;
import android.hardware.camera2.params.StreamConfigurationMap;
import android.media.Image;
import android.media.ImageReader;
import android.os.Handler;
import android.os.HandlerThread;
import android.util.Size;
import android.util.SparseArray;
import android.view.Surface;
import android.view.TextureView;
import android.view.View;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.List;

/**
 * Barcode scanners (fx.scanBarcode): Camera2 into an ImageReader, five frames a second turned
 * upright and handed to zui.barcode (in Zig, on the camera thread), and into the TextureView of
 * a ui.video that shows the scanner.
 */
final class ZuiScanner {
    /** "format\ttext" for a code found in the luminance `y` (w x h), or null. */
    static native String nativeDecode(byte[] y, int w, int h, int formats);
    /** kind: 1 started, 2 found, 3 failed (text: why). */
    static native void nativeScan(int id, int kind, int format, String text);

    static final int PERMISSION_REQUEST = 7201;

    static final class Scanner {
        int id, formats, viewId;
        boolean back, started, closed;
        CameraDevice camera;
        CameraCaptureSession session;
        ImageReader reader;
        Surface preview;
        Size size;
        int sensor;
        long last;
        byte[] gray;
    }

    static final SparseArray<Scanner> scanners = new SparseArray<>();
    static final ArrayList<Scanner> waiting = new ArrayList<>();
    static HandlerThread thread;
    static Handler handler;

    static void post(int id, int kind, int format, String text) {
        Zui.main.post(() -> {
            if (scanners.get(id) != null) nativeScan(id, kind, format, text);
            if (kind == 3) close(id);
        });
    }

    static void open(int id, int formats, boolean back) {
        Scanner s = new Scanner();
        s.id = id;
        s.formats = formats;
        s.back = back;
        scanners.put(id, s);
        if (Zui.activity.checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            waiting.add(s);
            Zui.activity.requestPermissions(new String[] {Manifest.permission.CAMERA}, PERMISSION_REQUEST);
            return;
        }
        start(s);
    }

    /** From the activity. */
    static boolean permissionResult(int code, int[] results) {
        if (code != PERMISSION_REQUEST) return false;
        boolean granted = results.length > 0 && results[0] == PackageManager.PERMISSION_GRANTED;
        for (Scanner s : waiting) {
            if (s.closed) continue;
            if (granted) start(s); else post(s.id, 3, 0, "denied");
        }
        waiting.clear();
        return true;
    }

    static void start(Scanner s) {
        if (thread == null) {
            thread = new HandlerThread("zui-scanner");
            thread.start();
            handler = new Handler(thread.getLooper());
        }
        try {
            CameraManager m = (CameraManager) Zui.activity.getSystemService(Context.CAMERA_SERVICE);
            String chosen = null;
            for (String cid : m.getCameraIdList()) {
                Integer facing = m.getCameraCharacteristics(cid).get(CameraCharacteristics.LENS_FACING);
                boolean isBack = facing != null && facing == CameraCharacteristics.LENS_FACING_BACK;
                if (isBack == s.back) {
                    chosen = cid;
                    break;
                }
                if (chosen == null) chosen = cid;
            }
            if (chosen == null) {
                post(s.id, 3, 0, "unavailable");
                return;
            }
            CameraCharacteristics c = m.getCameraCharacteristics(chosen);
            Integer orientation = c.get(CameraCharacteristics.SENSOR_ORIENTATION);
            s.sensor = orientation == null ? 90 : orientation;
            StreamConfigurationMap map = c.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
            // About 1280 x 720: enough for small codes, little to copy.
            Size best = null;
            for (Size z : map.getOutputSizes(ImageFormat.YUV_420_888)) {
                if (best == null || Math.abs(z.getWidth() * z.getHeight() - 1280 * 720) < Math.abs(best.getWidth() * best.getHeight() - 1280 * 720)) best = z;
            }
            s.size = best;
            s.reader = ImageReader.newInstance(best.getWidth(), best.getHeight(), ImageFormat.YUV_420_888, 2);
            s.reader.setOnImageAvailableListener(r -> frame(s, r), handler);
            m.openCamera(chosen, new CameraDevice.StateCallback() {
                @Override
                public void onOpened(CameraDevice camera) {
                    if (s.closed) {
                        camera.close();
                        return;
                    }
                    s.camera = camera;
                    session(s);
                }

                @Override
                public void onDisconnected(CameraDevice camera) {
                    camera.close();
                }

                @Override
                public void onError(CameraDevice camera, int error) {
                    android.util.Log.e("zui", "scanner: camera error " + error);
                    camera.close();
                    post(s.id, 3, 0, "unavailable");
                }
            }, handler);
        } catch (Exception e) {
            android.util.Log.e("zui", "scanner: " + e);
            post(s.id, 3, 0, e instanceof SecurityException ? "denied" : "unavailable");
        }
    }

    /** (Re)starts capturing into the reader, and the preview once there is one. */
    static void session(Scanner s) {
        if (s.camera == null || s.closed) return;
        try {
            if (s.session != null) s.session.close();
            List<Surface> targets = new ArrayList<>();
            targets.add(s.reader.getSurface());
            if (s.preview != null) targets.add(s.preview);
            s.camera.createCaptureSession(targets, new CameraCaptureSession.StateCallback() {
                @Override
                public void onConfigured(CameraCaptureSession session) {
                    if (s.closed) return;
                    s.session = session;
                    try {
                        CaptureRequest.Builder b = s.camera.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW);
                        for (Surface t : targets) b.addTarget(t);
                        b.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE);
                        session.setRepeatingRequest(b.build(), null, handler);
                        if (!s.started) {
                            s.started = true;
                            post(s.id, 1, 0, "");
                        }
                    } catch (Exception e) {
                        android.util.Log.e("zui", "scanner: " + e);
                        post(s.id, 3, 0, "unavailable");
                    }
                }

                @Override
                public void onConfigureFailed(CameraCaptureSession session) {
                    android.util.Log.e("zui", "scanner: session not configured");
                    post(s.id, 3, 0, "unavailable");
                }
            }, handler);
        } catch (Exception e) {
            android.util.Log.e("zui", "scanner: " + e);
            post(s.id, 3, 0, "unavailable");
        }
    }

    /** On the camera thread: every 200 ms, the luminance turned upright, decoded in Zig. */
    static void frame(Scanner s, ImageReader r) {
        Image img = r.acquireLatestImage();
        if (img == null) return;
        int w, h;
        try {
            long now = System.currentTimeMillis();
            if (s.closed || now - s.last < 200) return;
            s.last = now;
            Image.Plane y = img.getPlanes()[0];
            ByteBuffer buf = y.getBuffer();
            int stride = y.getRowStride(), pixel = y.getPixelStride();
            int sw = img.getWidth(), sh = img.getHeight();
            boolean turn = s.sensor == 90 || s.sensor == 270;
            w = turn ? sh : sw;
            h = turn ? sw : sh;
            if (s.gray == null || s.gray.length != w * h) s.gray = new byte[w * h];
            byte[] row = new byte[stride];
            for (int yy = 0; yy < sh; yy++) {
                buf.position(yy * stride);
                buf.get(row, 0, Math.min(stride, buf.remaining()));
                for (int xx = 0; xx < sw; xx++) {
                    byte v = row[xx * pixel];
                    int ux, uy;
                    switch (s.sensor) {
                        case 90: ux = sh - 1 - yy; uy = xx; break;
                        case 180: ux = sw - 1 - xx; uy = sh - 1 - yy; break;
                        case 270: ux = yy; uy = sw - 1 - xx; break;
                        default: ux = xx; uy = yy;
                    }
                    s.gray[uy * w + ux] = v;
                }
            }
        } finally {
            img.close();
        }
        String found = nativeDecode(s.gray, w, h, s.formats);
        if (found == null) return;
        int tab = found.indexOf('\t');
        post(s.id, 2, Integer.parseInt(found.substring(0, tab)), found.substring(tab + 1));
    }

    /** The video view `viewId` shows scanner `id`'s camera. */
    static void attach(int viewId, int id) {
        Scanner s = scanners.get(id);
        View v = Zui.views.get(viewId);
        if (s == null || !(v instanceof TextureView) || s.viewId == viewId) return;
        TextureView tv = (TextureView) v;
        if (!tv.isAvailable() || s.size == null) {
            // Not laid out yet, or the camera not chosen yet.
            tv.postDelayed(() -> attach(viewId, id), 100);
            return;
        }
        s.viewId = viewId;
        SurfaceTexture st = tv.getSurfaceTexture();
        st.setDefaultBufferSize(s.size.getWidth(), s.size.getHeight());
        s.preview = new Surface(st);
        fit(tv, s);
        tv.addOnLayoutChangeListener((view, l, t, rr, b, ol, ot, orr, ob) -> fit(tv, s));
        handler.post(() -> session(s));
    }

    /** The upright picture filling the view, cropped (as the web's object-fit: cover). */
    static void fit(TextureView tv, Scanner s) {
        float vw = tv.getWidth(), vh = tv.getHeight();
        if (vw <= 0 || vh <= 0 || s.size == null) return;
        boolean turn = s.sensor == 90 || s.sensor == 270;
        float cw = turn ? s.size.getHeight() : s.size.getWidth();
        float ch = turn ? s.size.getWidth() : s.size.getHeight();
        float ca = cw / ch, va = vw / vh;
        Matrix m = new Matrix();
        if (va > ca) m.setScale(1, va / ca, vw / 2, vh / 2); else m.setScale(ca / va, 1, vw / 2, vh / 2);
        tv.setTransform(m);
    }

    static void close(int id) {
        Scanner s = scanners.get(id);
        if (s == null) return;
        scanners.remove(id);
        s.closed = true;
        Handler h = handler;
        Runnable stop = () -> {
            try {
                if (s.session != null) s.session.close();
                if (s.camera != null) s.camera.close();
                if (s.reader != null) s.reader.close();
                if (s.preview != null) s.preview.release();
            } catch (Exception ignored) {
            }
        };
        if (h != null) h.post(stop); else stop.run();
    }
}
