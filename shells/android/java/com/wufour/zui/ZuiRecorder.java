package com.wufour.zui;

import android.Manifest;
import android.media.MediaRecorder;
import android.os.SystemClock;
import java.io.File;
import java.nio.file.Files;
import java.util.HashMap;

/**
 * Voice and video messages (fx.startRecording): MediaRecorder writes AAC in MP4 (.m4a) for
 * audio, H.264 + AAC in MP4 for video. For video the camera (ZuiMedia, Camera2) writes into the
 * recorder's input surface and into the video views showing the recorder. Everything runs on
 * the UI thread; events go to zui/host/android.zig.
 */
final class ZuiRecorder {
    static final int STARTED = 1, LEVEL = 2, DONE = 3, FAILED = 4;
    static final int WIDTH = 640, HEIGHT = 480;

    /** data: the file for DONE, the reason (UTF-8) for FAILED. */
    static native void nativeRecordEvent(int id, int kind, int levelPermille, int durationMs, byte[] data, String mime);

    static final class Rec {
        int id;
        boolean video, started;
        MediaRecorder recorder;
        File file;
        long startedAt;
        Runnable tick, limit;
    }

    static final HashMap<Integer, Rec> recs = new HashMap<>();

    static void start(int id, boolean video, boolean back, int maxMs) {
        String[] permissions = video ? new String[] {Manifest.permission.RECORD_AUDIO, Manifest.permission.CAMERA} : new String[] {Manifest.permission.RECORD_AUDIO};
        recs.put(id, new Rec()); // claims the id while asking
        ZuiMedia.withPermissions(permissions, granted -> {
            if (!recs.containsKey(id)) return; // cancelled meanwhile
            if (!granted) {
                recs.remove(id);
                failed(id, "denied");
                return;
            }
            begin(id, video, back, maxMs);
        });
    }

    @SuppressWarnings("deprecation")
    static void begin(int id, boolean video, boolean back, int maxMs) {
        Rec r = new Rec();
        r.id = id;
        r.video = video;
        recs.put(id, r);
        try {
            r.file = File.createTempFile("zui-rec", video ? ".mp4" : ".m4a", Zui.activity.getCacheDir());
            MediaRecorder m = new MediaRecorder();
            r.recorder = m;
            m.setAudioSource(MediaRecorder.AudioSource.MIC);
            if (video) m.setVideoSource(MediaRecorder.VideoSource.SURFACE);
            m.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4);
            m.setAudioEncoder(MediaRecorder.AudioEncoder.AAC);
            m.setAudioSamplingRate(44100);
            m.setAudioChannels(1);
            m.setAudioEncodingBitRate(video ? 96000 : 64000);
            if (video) {
                m.setVideoEncoder(MediaRecorder.VideoEncoder.H264);
                m.setVideoSize(WIDTH, HEIGHT);
                m.setVideoFrameRate(30);
                m.setVideoEncodingBitRate(1_200_000);
                m.setOrientationHint(ZuiMedia.cameraRotation(back));
            }
            m.setOutputFile(r.file.getAbsolutePath());
            m.prepare();
            if (!video) {
                m.start();
                started(r, maxMs);
                return;
            }
            ZuiMedia.openForRecorder(id, back, m.getSurface(), () -> {
                if (recs.get(id) != r || r.started) return;
                try {
                    m.start();
                    started(r, maxMs);
                } catch (Exception e) {
                    abort(r, "unavailable");
                }
            }, reason -> abort(r, reason));
        } catch (Exception e) {
            abort(r, "unavailable");
        }
    }

    static void started(Rec r, int maxMs) {
        r.started = true;
        r.startedAt = SystemClock.elapsedRealtime();
        nativeRecordEvent(r.id, STARTED, 0, 0, null, "");
        r.tick = new Runnable() {
            @Override
            public void run() {
                if (recs.get(r.id) != r) return;
                float level = 0;
                try {
                    // Peak amplitude since the last call, 0..32767; a square root reads more like loudness.
                    level = (float) Math.sqrt(Math.min(1.0, r.recorder.getMaxAmplitude() / 32767.0));
                } catch (Exception ignored) {
                }
                nativeRecordEvent(r.id, LEVEL, Math.round(level * 1000), elapsed(r), null, "");
                Zui.main.postDelayed(this, 100);
            }
        };
        Zui.main.postDelayed(r.tick, 100);
        r.limit = () -> {
            if (recs.get(r.id) == r) stop(r.id, false);
        };
        Zui.main.postDelayed(r.limit, Math.max(500, maxMs));
    }

    static int elapsed(Rec r) {
        return (int) (SystemClock.elapsedRealtime() - r.startedAt);
    }

    static void stop(int id, boolean cancel) {
        Rec r = recs.remove(id);
        if (r == null) return;
        if (r.tick != null) Zui.main.removeCallbacks(r.tick);
        if (r.limit != null) Zui.main.removeCallbacks(r.limit);
        if (r.video) ZuiMedia.close(id);
        if (r.recorder == null) {
            // Still asking for permission.
            if (!cancel) failed(id, "unavailable");
            return;
        }
        int duration = r.started ? elapsed(r) : 0;
        boolean ok = r.started;
        try {
            if (r.started) r.recorder.stop();
        } catch (RuntimeException e) {
            ok = false; // nothing recorded yet
        }
        r.recorder.release();
        byte[] data = null;
        if (ok && !cancel) {
            try {
                data = Files.readAllBytes(r.file.toPath());
            } catch (Exception e) {
                ok = false;
            }
        }
        if (r.file != null) r.file.delete();
        if (cancel) return;
        if (!ok) failed(id, "unavailable");
        else nativeRecordEvent(id, DONE, 0, duration, data, r.video ? "video/mp4" : "audio/mp4");
    }

    static void abort(Rec r, String reason) {
        if (recs.get(r.id) != r) return;
        recs.remove(r.id);
        if (r.tick != null) Zui.main.removeCallbacks(r.tick);
        if (r.limit != null) Zui.main.removeCallbacks(r.limit);
        if (r.video) ZuiMedia.close(r.id);
        if (r.recorder != null) r.recorder.release();
        if (r.file != null) r.file.delete();
        failed(r.id, reason);
    }

    static void failed(int id, String reason) {
        nativeRecordEvent(id, FAILED, 0, 0, reason.getBytes(java.nio.charset.StandardCharsets.UTF_8), "");
    }
}
