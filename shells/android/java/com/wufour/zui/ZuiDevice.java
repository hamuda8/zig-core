package com.wufour.zui;

import android.content.Context;
import android.content.Intent;
import android.media.AudioManager;
import android.media.ToneGenerator;
import android.net.ConnectivityManager;
import android.net.Network;
import android.os.Build;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.view.WindowManager;

/**
 * The device around the views: Back, the screen kept on, vibration and sound, the network and
 * the app going to the background. Called from zui's Zig code (host/android.zig) and from
 * ZuiActivity.
 */
final class ZuiDevice {
    static final int ONLINE = 1, OFFLINE = 2, VISIBLE = 3, HIDDEN = 4;

    // Implemented in Zig (libapp.so).
    /** Back: whether the app took it (its own handler, or a link to go back to). */
    static native boolean nativeBack();
    /** The app was opened again with a new address (a deep link). */
    static native void nativeLink(String link);
    static native void nativeDevice(int kind);

    // ---- Back ----

    /** The app handles Back now (zui told us); otherwise the activity's default (leave). */
    static boolean backWanted;

    static void backState(boolean handler, boolean history, boolean rtl) {
        boolean want = handler || history;
        if (want == backWanted) return;
        backWanted = want;
        if (Build.VERSION.SDK_INT >= 33) Back33.set(want);
    }

    /** From onBackPressed (Android 12 and older, or without the predictive back opt-in) and the
     *  Android 13+ callback. False: the activity does its default. */
    static boolean back() {
        return Zui.started && nativeBack();
    }

    /** Android 13+: the callback is registered only while the app handles Back, so the system
     *  can show its "back to home" animation when it does not. */
    static final class Back33 {
        static android.window.OnBackInvokedCallback callback;

        static void set(boolean on) {
            android.window.OnBackInvokedDispatcher d = Zui.activity.getOnBackInvokedDispatcher();
            if (callback == null) callback = () -> back();
            if (on) d.registerOnBackInvokedCallback(android.window.OnBackInvokedDispatcher.PRIORITY_DEFAULT, callback);
            else d.unregisterOnBackInvokedCallback(callback);
        }
    }

    static void link(String link) {
        if (Zui.started && link != null) nativeLink(link);
    }

    // ---- Visible / hidden, online / offline ----

    static void visible(boolean on) {
        if (Zui.started) nativeDevice(on ? VISIBLE : HIDDEN);
    }

    static boolean watchingNetwork;

    /** After start: the current state, then every change (needs ACCESS_NETWORK_STATE in the
     *  manifest; without it the app is taken to be online). */
    static void watchNetwork() {
        if (watchingNetwork) return;
        watchingNetwork = true;
        try {
            ConnectivityManager cm = (ConnectivityManager) Zui.activity.getSystemService(Context.CONNECTIVITY_SERVICE);
            if (cm.getActiveNetwork() == null) nativeDevice(OFFLINE);
            cm.registerDefaultNetworkCallback(new ConnectivityManager.NetworkCallback() {
                @Override
                public void onAvailable(Network n) {
                    Zui.main.post(() -> nativeDevice(ONLINE));
                }

                @Override
                public void onLost(Network n) {
                    Zui.main.post(() -> nativeDevice(OFFLINE));
                }
            });
        } catch (Exception ignored) {
            // no ACCESS_NETWORK_STATE
        }
    }

    // ---- Screen, vibration, sound ----

    static void keepAwake(boolean on) {
        if (on) Zui.activity.getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        else Zui.activity.getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    }

    /** Needs VIBRATE in the manifest; without it nothing happens. */
    static void vibrate(int ms) {
        try {
            Vibrator v = (Vibrator) Zui.activity.getSystemService(Context.VIBRATOR_SERVICE);
            if (v != null && v.hasVibrator()) v.vibrate(VibrationEffect.createOneShot(Math.max(1, ms), VibrationEffect.DEFAULT_AMPLITUDE));
        } catch (Exception ignored) {
        }
    }

    static ToneGenerator tones;

    static void beep() {
        try {
            if (tones == null) tones = new ToneGenerator(AudioManager.STREAM_NOTIFICATION, 80);
            tones.startTone(ToneGenerator.TONE_PROP_BEEP, 150);
        } catch (Exception ignored) {
            // no audio focus / tone generator
        }
    }
}
