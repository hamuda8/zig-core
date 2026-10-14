package com.wufour.zui;

import android.app.Activity;
import android.content.res.Configuration;
import android.graphics.Insets;
import android.os.Build;
import android.net.http.HttpResponseCache;
import android.os.Bundle;
import java.io.File;
import android.view.View;
import android.view.Window;
import android.view.WindowInsets;

/** Fixed Android entry for every zui app. Everything visible is created by the app's Zig code (libapp.so). */
public final class ZuiActivity extends Activity {
    static {
        System.loadLibrary("app");
    }

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        Zui.activity = this;
        Zui.density = getResources().getDisplayMetrics().density;
        Zui.dark = isDark(getResources().getConfiguration());
        if (getIntent() != null && getIntent().getData() != null) Zui.link = getIntent().getDataString();
        showOverLockScreen(getIntent());
        ZuiCallService.fromIntent(this, getIntent());
        // Disk cache for downloaded images (map tiles), kept across launches.
        try {
            HttpResponseCache.install(new File(getCacheDir(), "http"), 100L * 1024 * 1024);
        } catch (Exception ignored) {
        }

        // Draw behind the system bars; zui keeps content out of them with the insets.
        Window w = getWindow();
        if (Build.VERSION.SDK_INT >= 30) {
            w.setDecorFitsSystemWindows(false);
        } else {
            w.getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                    | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION);
        }
        w.setStatusBarColor(0);
        w.setNavigationBarColor(0);

        ZuiLayout root = new ZuiLayout(this);
        root.isRoot = true;
        Zui.root = root;
        root.setOnApplyWindowInsetsListener((v, insets) -> {
            if (Build.VERSION.SDK_INT >= 30) {
                Insets i = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout() | WindowInsets.Type.ime());
                Zui.insets(i.top, i.right, i.bottom, i.left);
            } else {
                Zui.insets(insets.getSystemWindowInsetTop(), insets.getSystemWindowInsetRight(),
                        insets.getSystemWindowInsetBottom(), insets.getSystemWindowInsetLeft());
            }
            return insets;
        });
        setContentView(root);
    }

    @Override
    public boolean dispatchKeyEvent(android.view.KeyEvent e) {
        if (ZuiDevice.key(e, getCurrentFocus())) return true;
        return super.dispatchKeyEvent(e);
    }

    /** An urgent notification (dispatch alarm, call) opens the app over the lock screen. */
    void showOverLockScreen(android.content.Intent intent) {
        if (intent == null || !intent.getBooleanExtra("zui_alert", false)) return;
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(true);
            setTurnScreenOn(true);
        }
    }

    @Override
    protected void onNewIntent(android.content.Intent intent) {
        super.onNewIntent(intent);
        showOverLockScreen(intent);
        ZuiCallService.fromIntent(this, intent);
        if (intent != null && intent.getData() != null) ZuiDevice.link(intent.getDataString());
    }

    @Override
    protected void onActivityResult(int code, int result, android.content.Intent data) {
        if (!ZuiDevice.activityResult(code, result, data)) super.onActivityResult(code, result, data);
    }

    @Override
    public void onBackPressed() {
        if (!ZuiDevice.back()) super.onBackPressed();
    }

    @Override
    protected void onStart() {
        super.onStart();
        ZuiDevice.visible(true);
    }

    @Override
    protected void onStop() {
        super.onStop();
        ZuiDevice.visible(false);
    }

    @Override
    public void onRequestPermissionsResult(int code, String[] permissions, int[] results) {
        if (ZuiDevice.permissionResult(code, results)) return;
        if (ZuiScanner.permissionResult(code, results)) return;
        if (code == ZuiMedia.PERMISSION_REQUEST) {
            ZuiMedia.permissionResult(permissions, results);
            return;
        }
        if (code != Zui.LOCATION_REQUEST) return;
        boolean granted = false;
        for (int r : results) granted |= r == android.content.pm.PackageManager.PERMISSION_GRANTED;
        Zui.locationPermission(granted);
    }

    @Override
    public void onConfigurationChanged(Configuration c) {
        super.onConfigurationChanged(c);
        Zui.darkChanged(isDark(c));
    }

    static boolean isDark(Configuration c) {
        return (c.uiMode & Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES;
    }
}
