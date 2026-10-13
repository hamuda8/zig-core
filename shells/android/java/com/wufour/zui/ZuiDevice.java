package com.wufour.zui;

import android.app.AlertDialog;
import android.app.DatePickerDialog;
import android.app.TimePickerDialog;
import android.content.Context;
import android.graphics.Typeface;
import android.text.InputType;
import android.view.View;
import android.view.inputmethod.EditorInfo;
import android.widget.EditText;
import java.util.Calendar;
import java.util.Locale;
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
    /** A picker's answer: "YYYY-MM-DD", "HH:MM", or the index of the option chosen. */
    static native void nativePickDone(String value);

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

    // ---- Inputs: keyboard, enter key, password ----

    static void inputType(int id, int keyboard, int returnKey, boolean secure) {
        View v = Zui.views.get(id);
        if (!(v instanceof EditText)) return;
        EditText e = (EditText) v;
        boolean area = (e.getInputType() & InputType.TYPE_TEXT_FLAG_MULTI_LINE) != 0;
        int t;
        switch (keyboard) {
            case 1: t = InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS; break;
            case 2: t = InputType.TYPE_CLASS_NUMBER; break;
            case 3: t = InputType.TYPE_CLASS_PHONE; break;
            case 4: t = InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI; break;
            case 5: t = InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_FLAG_DECIMAL; break;
            default: t = InputType.TYPE_CLASS_TEXT | (area ? InputType.TYPE_TEXT_FLAG_CAP_SENTENCES : 0);
        }
        if (secure) t = keyboard == 2 ? InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_VARIATION_PASSWORD : InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD;
        if (area) t |= InputType.TYPE_TEXT_FLAG_MULTI_LINE;
        // A password type switches the font to monospace: keep zui's.
        Typeface face = e.getTypeface();
        int at = e.getSelectionEnd();
        e.setInputType(t);
        e.setTypeface(face);
        if (at >= 0) e.setSelection(Math.min(at, e.length()));
        int[] actions = {area ? EditorInfo.IME_ACTION_NONE : EditorInfo.IME_ACTION_DONE, EditorInfo.IME_ACTION_DONE, EditorInfo.IME_ACTION_GO,
                EditorInfo.IME_ACTION_NEXT, EditorInfo.IME_ACTION_SEARCH, EditorInfo.IME_ACTION_SEND};
        e.setImeOptions(actions[Math.max(0, Math.min(returnKey, actions.length - 1))]);
    }

    // ---- Pickers: the platform's date and time dialogs and a list dialog ----

    static final int PICK_DATE = 1, PICK_TIME = 2, PICK_OPTION = 3;

    static void picked(String value) {
        if (Zui.started) nativePickDone(value);
    }

    /** "YYYY-MM-DD" (or "HH:MM") as numbers, or null. */
    static int[] numbers(String s, String sep, int count) {
        String[] parts = s.split(sep);
        if (parts.length != count) return null;
        int[] out = new int[count];
        try {
            for (int i = 0; i < count; i++) out[i] = Integer.parseInt(parts[i].trim());
        } catch (NumberFormatException e) {
            return null;
        }
        return out;
    }

    static long dayMillis(String day) {
        int[] d = numbers(day, "-", 3);
        if (d == null) return -1;
        Calendar c = Calendar.getInstance();
        c.clear();
        c.set(d[0], d[1] - 1, d[2]);
        return c.getTimeInMillis();
    }

    static void pick(int kind, String value, String min, String max, String title, String options, int selected) {
        android.app.Activity a = Zui.activity;
        int theme = Zui.dark ? android.R.style.Theme_DeviceDefault_Dialog_Alert : android.R.style.Theme_DeviceDefault_Light_Dialog_Alert;
        if (kind == PICK_DATE) {
            Calendar now = Calendar.getInstance();
            int[] d = numbers(value, "-", 3);
            if (d == null) d = new int[] {now.get(Calendar.YEAR), now.get(Calendar.MONTH) + 1, now.get(Calendar.DAY_OF_MONTH)};
            DatePickerDialog dialog = new DatePickerDialog(a, theme,
                    (view, y, m, day) -> picked(String.format(Locale.ROOT, "%04d-%02d-%02d", y, m + 1, day)), d[0], d[1] - 1, d[2]);
            long lo = dayMillis(min), hi = dayMillis(max);
            if (lo >= 0) dialog.getDatePicker().setMinDate(lo);
            if (hi >= 0) dialog.getDatePicker().setMaxDate(hi);
            dialog.show();
        } else if (kind == PICK_TIME) {
            Calendar now = Calendar.getInstance();
            int[] t = numbers(value, ":", 2);
            if (t == null) t = new int[] {now.get(Calendar.HOUR_OF_DAY), now.get(Calendar.MINUTE)};
            new TimePickerDialog(a, theme, (view, h, m) -> picked(String.format(Locale.ROOT, "%02d:%02d", h, m)), t[0], t[1],
                    android.text.format.DateFormat.is24HourFormat(a)).show();
        } else {
            String[] items = options.isEmpty() ? new String[0] : options.split("\n", -1);
            AlertDialog.Builder b = new AlertDialog.Builder(a, theme);
            if (!title.isEmpty()) b.setTitle(title);
            b.setSingleChoiceItems(items, selected, (dialog, which) -> {
                dialog.dismiss();
                picked(String.valueOf(which));
            });
            b.show();
        }
    }
}
