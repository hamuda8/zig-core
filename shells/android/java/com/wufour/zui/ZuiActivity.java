package com.wufour.zui;

import android.app.Activity;
import android.os.Bundle;

/** Fixed Android entry for every zui app. Everything visible is created by the app's Zig code (libapp.so). */
public final class ZuiActivity extends Activity {
    static {
        System.loadLibrary("app");
    }

    private static native void nativeStart(Activity activity);

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        nativeStart(this);
    }
}
