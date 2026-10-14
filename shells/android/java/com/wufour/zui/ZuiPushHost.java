package com.wufour.zui;

import android.Manifest;
import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Looper;
import android.util.Log;
import java.util.Locale;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * Push for every zui app, without Firebase types: ZuiPush (shells/android/push, compiled only
 * for apps built with `addApp(.android_push)`) receives from Firebase Cloud Messaging and hands
 * over here; it is reached by reflection, so apps without push need no Firebase at all.
 *
 * How a push reaches the app's Zig code:
 *   - The app is open: the data map, as JSON, goes to the app's `pushMessage` on the UI thread.
 *   - The app is in the background (process alive, activity stopped): the same; zui keeps
 *     drawing into the stopped activity, which the user sees on return.
 *   - The app is not running (swiped away, force-stopped, after a reboot): Google Play
 *     services starts the process for a high-priority data message and ZuiPush's
 *     onMessageReceived runs, with no activity. The Zig side is then started without a screen
 *     (`nativeStartHeadless`: the app's `init` runs, nothing is drawn, `boot` waits) and the
 *     message is delivered. The app answers as it would on screen: `fx.notify(.urgent)` (a
 *     dispatch alarm: full-screen intent over the lock screen) or `fx.ringCall` (ZuiCallService:
 *     the system's ringing call). Zui's effects use the application context while there is no
 *     activity. When the user then opens the app, the activity's first layout calls nativeStart,
 *     which brings the screen to the state the push left (and runs `boot`).
 *     onMessageReceived waits (up to 10 s) until the Zig side has handled the message, so the
 *     process is not dropped before the call rings. A force-stopped app gets no pushes at all
 *     until it is opened again (Android's rule, not ours).
 *   - Tokens: delivered to the app's `pushToken` once its screen is up (they need the
 *     signed-in user to be sent anywhere); a newer one replaces one still waiting.
 */
public final class ZuiPushHost {
    static final int FCM = 1;
    static final int NOTIFICATION_REQUEST = 7004;

    static native void nativeToken(String token, int kind);
    static native void nativeMessage(String json);
    static native void nativeStartHeadless(String lang);

    /** The Zig side runs without the activity (started for a push). */
    static boolean headless;
    static String pendingToken;

    /** From Zig: fx.registerPush. */
    static void register() {
        Context c = Zui.ctx();
        if (Zui.activity != null && Build.VERSION.SDK_INT >= 33
                && Zui.activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            Zui.activity.requestPermissions(new String[] {Manifest.permission.POST_NOTIFICATIONS}, NOTIFICATION_REQUEST);
        }
        try {
            Class.forName("com.wufour.zui.ZuiPush").getMethod("register", Context.class).invoke(null, c);
        } catch (ClassNotFoundException e) {
            Log.w("zui", "push: this app is built without android_push");
        } catch (Exception e) {
            Log.e("zui", "push: " + e);
        }
    }

    /** A new token (any thread). */
    static void token(String token) {
        Zui.main.post(() -> {
            if (Zui.started) nativeToken(token, FCM);
            else pendingToken = token;
        });
    }

    /** The screen is up (Zui.rootSized): the token that waited. */
    static void flush() {
        if (pendingToken == null) return;
        String t = pendingToken;
        pendingToken = null;
        nativeToken(t, FCM);
    }

    /** A push's data as JSON (any thread). Returns once the app's Zig code has handled it. */
    static void message(Context c, String json) {
        CountDownLatch done = new CountDownLatch(1);
        Zui.main.post(() -> {
            try {
                ensureRunning(c);
                nativeMessage(json);
            } catch (Throwable t) {
                Log.e("zui", "push: " + t);
            } finally {
                done.countDown();
            }
        });
        if (Looper.myLooper() == Looper.getMainLooper()) return;
        try {
            done.await(10, TimeUnit.SECONDS);
        } catch (InterruptedException ignored) {
        }
    }

    /** Starts the Zig side without a screen if nothing started it yet (UI thread). */
    static void ensureRunning(Context c) {
        if (Zui.started || headless) return;
        if (Zui.app == null) Zui.app = c.getApplicationContext();
        Zui.density = c.getResources().getDisplayMetrics().density;
        System.loadLibrary("app");
        headless = true;
        nativeStartHeadless(Locale.getDefault().toLanguageTag());
    }
}
