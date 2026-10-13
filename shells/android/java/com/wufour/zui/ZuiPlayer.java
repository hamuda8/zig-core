package com.wufour.zui;

import android.media.AudioAttributes;
import android.media.MediaPlayer;
import android.os.Build;
import java.io.File;
import java.io.FileOutputStream;
import java.util.HashMap;

/**
 * Playback (fx.play): MediaPlayer, from a URL or from bytes (written to a cache file). A video
 * plays into the video view showing the player (ZuiMedia's TextureViews). UI thread only.
 */
final class ZuiPlayer {
    static final int READY = 1, PROGRESS = 2, ENDED = 3, FAILED = 4;

    static native void nativePlayEvent(int id, int kind, int positionMs, int durationMs, String reason);

    static final class P {
        int id, width, height;
        boolean video, prepared, autoplay;
        MediaPlayer player;
        File file;
        Runnable tick;
        ZuiMedia.VideoView view;
    }

    static final HashMap<Integer, P> players = new HashMap<>();

    static void play(int id, String url, byte[] data, String mime, boolean video, boolean autoplay, boolean loop) {
        P p = new P();
        p.id = id;
        p.video = video;
        p.autoplay = autoplay;
        players.put(id, p);
        MediaPlayer m = new MediaPlayer();
        p.player = m;
        try {
            m.setAudioAttributes(new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(video ? AudioAttributes.CONTENT_TYPE_MOVIE : AudioAttributes.CONTENT_TYPE_SPEECH).build());
            if (data != null && data.length > 0) {
                p.file = File.createTempFile("zui-play", extension(mime), Zui.activity.getCacheDir());
                try (FileOutputStream out = new FileOutputStream(p.file)) {
                    out.write(data);
                }
                m.setDataSource(p.file.getAbsolutePath());
            } else {
                m.setDataSource(url);
            }
            m.setLooping(loop);
            m.setOnPreparedListener(mp -> {
                if (players.get(id) != p) return;
                p.prepared = true;
                event(p, READY);
                if (p.autoplay) resume(p);
            });
            m.setOnCompletionListener(mp -> {
                if (players.get(id) != p) return;
                stopTicking(p);
                nativePlayEvent(id, ENDED, duration(p), duration(p), null);
            });
            m.setOnErrorListener((mp, what, extra) -> {
                if (players.get(id) == p) {
                    release(p);
                    nativePlayEvent(id, FAILED, 0, 0, "unavailable");
                }
                return true;
            });
            m.setOnVideoSizeChangedListener((mp, w, h) -> {
                p.width = w;
                p.height = h;
                if (p.view != null) show(p, p.view);
            });
            m.setOnSeekCompleteListener(mp -> {
                if (players.get(id) == p) event(p, PROGRESS);
            });
            if (p.view != null && p.view.surface != null) m.setSurface(p.view.surface);
            m.prepareAsync();
        } catch (Exception e) {
            release(p);
            Zui.main.post(() -> nativePlayEvent(id, FAILED, 0, 0, "unavailable"));
        }
    }

    static String extension(String mime) {
        if (mime == null) return ".bin";
        if (mime.contains("webm")) return ".webm";
        if (mime.contains("ogg")) return ".ogg";
        if (mime.contains("mpeg")) return ".mp3";
        if (mime.contains("wav")) return ".wav";
        return mime.startsWith("video") ? ".mp4" : ".m4a";
    }

    /** op: 1 pause, 2 play, 3 seek to value ms, 4 stop. */
    static void control(int id, int op, int value) {
        P p = players.get(id);
        if (p == null) return;
        switch (op) {
            case 1:
                p.autoplay = false;
                if (p.prepared && p.player.isPlaying()) p.player.pause();
                stopTicking(p);
                if (p.prepared) event(p, PROGRESS);
                break;
            case 2:
                p.autoplay = true;
                if (p.prepared) resume(p);
                break;
            case 3:
                if (!p.prepared) break;
                if (Build.VERSION.SDK_INT >= 26) p.player.seekTo((long) value, MediaPlayer.SEEK_CLOSEST);
                else p.player.seekTo(value);
                break;
            case 4:
                release(p);
                break;
        }
    }

    static void resume(P p) {
        p.player.start();
        if (p.tick != null) return;
        p.tick = new Runnable() {
            @Override
            public void run() {
                if (players.get(p.id) != p) return;
                event(p, PROGRESS);
                Zui.main.postDelayed(this, 250);
            }
        };
        Zui.main.postDelayed(p.tick, 250);
    }

    static void stopTicking(P p) {
        if (p.tick != null) Zui.main.removeCallbacks(p.tick);
        p.tick = null;
    }

    static int duration(P p) {
        try {
            return Math.max(0, p.player.getDuration());
        } catch (Exception e) {
            return 0;
        }
    }

    static void event(P p, int kind) {
        int position = 0;
        try {
            position = p.player.getCurrentPosition();
        } catch (Exception ignored) {
        }
        nativePlayEvent(p.id, kind, position, duration(p), null);
    }

    static void release(P p) {
        players.remove(p.id);
        stopTicking(p);
        if (p.view != null) p.view.view.setTransform(null);
        p.view = null;
        try {
            p.player.release();
        } catch (Exception ignored) {
        }
        if (p.file != null) p.file.delete();
    }

    // ---- video views (from ZuiMedia) ----

    /** A view now shows stream v.stream: true when that is a player. */
    static boolean attach(ZuiMedia.VideoView v) {
        P p = players.get(v.stream);
        if (p == null) return false;
        p.view = v;
        try {
            p.player.setSurface(v.surface);
        } catch (Exception ignored) {
        }
        show(p, v);
        return true;
    }

    static boolean detach(ZuiMedia.VideoView v) {
        P p = players.get(v.stream);
        if (p == null) return false;
        if (p.view == v) {
            p.view = null;
            try {
                p.player.setSurface(null);
            } catch (Exception ignored) {
            }
        }
        return true;
    }

    /** Fits (or covers) the video into the view. */
    static void show(P p, ZuiMedia.VideoView v) {
        if (p.width <= 0 || p.height <= 0) return;
        v.width = p.width;
        v.height = p.height;
        v.rotation = 0;
        ZuiMedia.transform(v);
    }
}
