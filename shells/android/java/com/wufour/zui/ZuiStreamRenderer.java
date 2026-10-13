package com.wufour.zui;

import android.graphics.SurfaceTexture;
import android.opengl.EGL14;
import android.opengl.EGLConfig;
import android.opengl.EGLContext;
import android.opengl.EGLDisplay;
import android.opengl.EGLSurface;
import android.opengl.GLES11Ext;
import android.opengl.GLES20;
import android.os.Handler;
import android.os.HandlerThread;
import android.view.Surface;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;
import java.util.ArrayList;

/**
 * One remote video stream drawn into any number of views (a call grid plus a
 * picture-in-picture). The decoder renders into this renderer's own SurfaceTexture; every new
 * frame is drawn with OpenGL ES into each attached TextureView, fitted or filling, turned by the
 * stream's rotation and mirrored as each view asks. All GL work runs on the renderer's thread.
 */
final class ZuiStreamRenderer implements SurfaceTexture.OnFrameAvailableListener {
    static final class Target {
        SurfaceTexture texture;
        EGLSurface egl = EGL14.EGL_NO_SURFACE;
        volatile boolean mirror, cover;
    }

    private final HandlerThread thread;
    private final Handler gl;
    private EGLDisplay display = EGL14.EGL_NO_DISPLAY;
    private EGLContext context = EGL14.EGL_NO_CONTEXT;
    private EGLConfig config;
    private EGLSurface pbuffer = EGL14.EGL_NO_SURFACE;
    private int program, oesTexture, aPos, aUv, uTex;
    private SurfaceTexture input;
    /** Handed to the decoder (native) once. */
    Surface surface;
    private final ArrayList<Target> targets = new ArrayList<>();
    private final float[] texMatrix = new float[16];
    /** Picture size as decoded and its rotation (degrees clockwise), from the decoder thread. */
    volatile int width, height, rotation;
    private boolean haveFrame;

    ZuiStreamRenderer() {
        thread = new HandlerThread("zui-video");
        thread.start();
        gl = new Handler(thread.getLooper());
        final Object ready = new Object();
        gl.post(() -> {
            setUp();
            synchronized (ready) {
                ready.notifyAll();
            }
        });
        synchronized (ready) {
            while (surface == null) {
                try {
                    ready.wait(2000);
                } catch (InterruptedException ignored) {
                }
                if (surface == null) break;
            }
        }
    }

    private void setUp() {
        display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY);
        int[] version = new int[2];
        EGL14.eglInitialize(display, version, 0, version, 1);
        int[] attribs = {EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT, EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT | EGL14.EGL_PBUFFER_BIT, EGL14.EGL_NONE};
        EGLConfig[] configs = new EGLConfig[1];
        int[] count = new int[1];
        EGL14.eglChooseConfig(display, attribs, 0, configs, 0, 1, count, 0);
        config = configs[0];
        context = EGL14.eglCreateContext(display, config, EGL14.EGL_NO_CONTEXT, new int[] {EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE}, 0);
        // A tiny pbuffer keeps the context current when no view is attached.
        pbuffer = EGL14.eglCreatePbufferSurface(display, config, new int[] {EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE}, 0);
        EGL14.eglMakeCurrent(display, pbuffer, pbuffer, context);

        program = link(
            "attribute vec2 pos; attribute vec2 uv; uniform mat4 m; varying vec2 v;\n"
                + "void main() { gl_Position = vec4(pos, 0.0, 1.0); v = (m * vec4(uv, 0.0, 1.0)).xy; }",
            "#extension GL_OES_EGL_image_external : require\n"
                + "precision mediump float; varying vec2 v; uniform samplerExternalOES t;\n"
                + "void main() { gl_FragColor = texture2D(t, v); }");
        aPos = GLES20.glGetAttribLocation(program, "pos");
        aUv = GLES20.glGetAttribLocation(program, "uv");
        uTex = GLES20.glGetUniformLocation(program, "m");

        int[] tex = new int[1];
        GLES20.glGenTextures(1, tex, 0);
        oesTexture = tex[0];
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTexture);
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR);
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR);
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE);
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE);
        input = new SurfaceTexture(oesTexture);
        input.setOnFrameAvailableListener(this, gl);
        surface = new Surface(input);
    }

    private static int compile(int type, String src) {
        int s = GLES20.glCreateShader(type);
        GLES20.glShaderSource(s, src);
        GLES20.glCompileShader(s);
        return s;
    }

    private static int link(String vertex, String fragment) {
        int p = GLES20.glCreateProgram();
        GLES20.glAttachShader(p, compile(GLES20.GL_VERTEX_SHADER, vertex));
        GLES20.glAttachShader(p, compile(GLES20.GL_FRAGMENT_SHADER, fragment));
        GLES20.glLinkProgram(p);
        return p;
    }

    /** A view's SurfaceTexture starts (or stops) showing this stream. */
    void attach(SurfaceTexture texture, boolean mirror, boolean cover) {
        gl.post(() -> {
            for (Target t : targets) if (t.texture == texture) {
                t.mirror = mirror;
                t.cover = cover;
                draw();
                return;
            }
            Target t = new Target();
            t.texture = texture;
            t.mirror = mirror;
            t.cover = cover;
            t.egl = EGL14.eglCreateWindowSurface(display, config, texture, new int[] {EGL14.EGL_NONE}, 0);
            targets.add(t);
            draw();
        });
    }

    /** Blocks until the view's surface is released here: TextureView frees it right after. */
    void detach(SurfaceTexture texture) {
        final Object done = new Object();
        final boolean[] finished = {false};
        gl.post(() -> {
            for (int i = 0; i < targets.size(); i++) {
                Target t = targets.get(i);
                if (t.texture != texture) continue;
                EGL14.eglMakeCurrent(display, pbuffer, pbuffer, context);
                EGL14.eglDestroySurface(display, t.egl);
                targets.remove(i);
                break;
            }
            synchronized (done) {
                finished[0] = true;
                done.notifyAll();
            }
        });
        synchronized (done) {
            if (!finished[0]) {
                try {
                    done.wait(1000);
                } catch (InterruptedException ignored) {
                }
            }
        }
    }

    /** Redraws (size or rotation changed). */
    void refresh() {
        gl.post(this::draw);
    }

    @Override
    public void onFrameAvailable(SurfaceTexture st) {
        EGL14.eglMakeCurrent(display, pbuffer, pbuffer, context);
        input.updateTexImage();
        input.getTransformMatrix(texMatrix);
        haveFrame = true;
        draw();
    }

    private final FloatBuffer quad = ByteBuffer.allocateDirect(16 * 4).order(ByteOrder.nativeOrder()).asFloatBuffer();

    private void draw() {
        if (!haveFrame || width <= 0 || height <= 0) return;
        for (Target t : targets) {
            if (!EGL14.eglMakeCurrent(display, t.egl, t.egl, context)) continue;
            int[] size = new int[2];
            EGL14.eglQuerySurface(display, t.egl, EGL14.EGL_WIDTH, size, 0);
            EGL14.eglQuerySurface(display, t.egl, EGL14.EGL_HEIGHT, size, 1);
            float vw = size[0], vh = size[1];
            if (vw <= 0 || vh <= 0) continue;
            GLES20.glViewport(0, 0, size[0], size[1]);
            GLES20.glClearColor(0, 0, 0, 1);
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);

            // The picture's displayed size (after turning), fitted or filling the view, in
            // normalised device coordinates (the quad may exceed [-1, 1]; GL clips it).
            boolean sideways = rotation % 180 != 0;
            float dw = sideways ? height : width, dh = sideways ? width : height;
            float s = t.cover ? Math.max(vw / dw, vh / dh) : Math.min(vw / dw, vh / dh);
            float hx = dw * s / vw, hy = dh * s / vh;
            // Each corner's texture coordinate: the display position turned back by the
            // rotation (and flipped first when mirrored).
            double r = Math.toRadians(rotation);
            float cos = (float) Math.cos(r), sin = (float) Math.sin(r);
            float[][] corners = {{-1, -1}, {1, -1}, {-1, 1}, {1, 1}};
            quad.clear();
            for (float[] c : corners) {
                float du = (t.mirror ? -c[0] : c[0]) * 0.5f, dv = c[1] * 0.5f;
                float u = cos * du - sin * dv + 0.5f, v = sin * du + cos * dv + 0.5f;
                quad.put(c[0] * hx).put(c[1] * hy).put(u).put(v);
            }
            quad.position(0);
            GLES20.glUseProgram(program);
            GLES20.glVertexAttribPointer(aPos, 2, GLES20.GL_FLOAT, false, 16, quad);
            GLES20.glEnableVertexAttribArray(aPos);
            quad.position(2);
            GLES20.glVertexAttribPointer(aUv, 2, GLES20.GL_FLOAT, false, 16, quad);
            GLES20.glEnableVertexAttribArray(aUv);
            GLES20.glUniformMatrix4fv(uTex, 1, false, texMatrix, 0);
            GLES20.glActiveTexture(GLES20.GL_TEXTURE0);
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTexture);
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4);
            EGL14.eglSwapBuffers(display, t.egl);
        }
    }

    /** The stream ended: everything goes. */
    void release() {
        gl.post(() -> {
            EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT);
            for (Target t : targets) EGL14.eglDestroySurface(display, t.egl);
            targets.clear();
            if (surface != null) surface.release();
            if (input != null) input.release();
            EGL14.eglDestroySurface(display, pbuffer);
            EGL14.eglDestroyContext(display, context);
            EGL14.eglTerminate(display);
            thread.quitSafely();
        });
    }
}
