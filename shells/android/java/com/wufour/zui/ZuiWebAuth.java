package com.wufour.zui;

import android.annotation.SuppressLint;
import android.app.Dialog;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.Insets;
import android.os.Build;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowInsets;
import android.view.WindowManager;
import android.webkit.CookieManager;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;

/**
 * fx.webAuth: a sign-in page (Wufour's) shown inside the app, full screen over the activity,
 * with no address bar: only a close button. JavaScript, DOM storage and cookies are on, so the
 * site's own session works and is kept for the next time. A navigation to anything starting
 * with the callback prefix is not loaded: its address goes back to Zig and the page closes.
 * Close, Back on the first page, or the dialog going away answer "cancelled" (null).
 */
final class ZuiWebAuth {
    /** The callback address that ended the sign-in, or null when the user closed it. */
    static native void nativeWebAuthDone(String url);

    static Dialog dialog;
    static WebView web;
    static String prefix;
    static boolean answered;

    @SuppressLint("SetJavaScriptEnabled")
    static void open(String url, String callbackPrefix) {
        // A page still open is replaced without an answer (zui already forgot its callback).
        if (dialog != null) {
            answered = true;
            close(null);
        }
        android.app.Activity a = Zui.activity;
        if (a == null) {
            done(null);
            return;
        }
        prefix = callbackPrefix;
        answered = false;
        final float d = a.getResources().getDisplayMetrics().density;
        final int bg = Zui.dark ? Color.rgb(18, 18, 20) : Color.WHITE;
        final int ink = Zui.dark ? Color.rgb(236, 236, 240) : Color.rgb(28, 28, 32);

        Dialog dlg = new Dialog(a, android.R.style.Theme_DeviceDefault_Light_NoActionBar) {
            @Override
            public void onBackPressed() {
                if (web != null && web.canGoBack()) web.goBack();
                else close(null);
            }
        };
        dlg.setOnCancelListener(x -> close(null));
        dlg.setOnDismissListener(x -> {
            if (dialog == x) close(null);
        });

        LinearLayout root = new LinearLayout(a);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(bg);

        // The bar: a close button only (no address, nothing of a browser).
        FrameLayout bar = new FrameLayout(a);
        TextView x = new TextView(a);
        x.setText("✕");
        x.setTextSize(20);
        x.setTextColor(ink);
        x.setGravity(Gravity.CENTER);
        x.setContentDescription(a.getString(android.R.string.cancel));
        android.util.TypedValue tv = new android.util.TypedValue();
        if (a.getTheme().resolveAttribute(android.R.attr.selectableItemBackgroundBorderless, tv, true)) x.setBackgroundResource(tv.resourceId);
        x.setOnClickListener(v -> close(null));
        FrameLayout.LayoutParams xp = new FrameLayout.LayoutParams((int) (48 * d), (int) (48 * d), Gravity.CENTER_VERTICAL | Gravity.START);
        xp.setMarginStart((int) (4 * d));
        bar.addView(x, xp);
        ProgressBar progress = new ProgressBar(a, null, android.R.attr.progressBarStyleHorizontal);
        progress.setIndeterminate(true);
        FrameLayout.LayoutParams pp = new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, (int) (3 * d), Gravity.BOTTOM);
        bar.addView(progress, pp);
        root.addView(bar, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, (int) (52 * d)));

        WebView w = new WebView(a);
        w.setBackgroundColor(bg);
        WebSettings s = w.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setSupportMultipleWindows(false);
        s.setJavaScriptCanOpenWindowsAutomatically(false);
        CookieManager cookies = CookieManager.getInstance();
        cookies.setAcceptCookie(true);
        cookies.setAcceptThirdPartyCookies(w, true);
        w.setWebChromeClient(new WebChromeClient() {
            @Override
            public void onProgressChanged(WebView view, int p) {
                progress.setVisibility(p >= 100 ? View.INVISIBLE : View.VISIBLE);
            }
        });
        w.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest req) {
                return intercept(req.getUrl().toString());
            }

            @Override
            @SuppressWarnings("deprecation")
            public boolean shouldOverrideUrlLoading(WebView view, String url) {
                return intercept(url);
            }

            @Override
            public void onPageStarted(WebView view, String url, Bitmap icon) {
                // A navigation that did not ask first (a redirect after a form post).
                if (url != null && prefix != null && url.startsWith(prefix)) {
                    view.stopLoading();
                    intercept(url);
                    return;
                }
                progress.setVisibility(View.VISIBLE);
            }
        });
        root.addView(w, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));

        // Keep the page out of the status bar, the navigation bar and the keyboard.
        root.setOnApplyWindowInsetsListener((v, insets) -> {
            if (Build.VERSION.SDK_INT >= 30) {
                Insets i = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout() | WindowInsets.Type.ime());
                v.setPadding(i.left, i.top, i.right, i.bottom);
            } else {
                v.setPadding(insets.getSystemWindowInsetLeft(), insets.getSystemWindowInsetTop(),
                        insets.getSystemWindowInsetRight(), insets.getSystemWindowInsetBottom());
            }
            return insets;
        });

        dlg.requestWindowFeature(Window.FEATURE_NO_TITLE);
        dlg.setContentView(root);
        Window win = dlg.getWindow();
        if (win != null) {
            win.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT);
            win.setBackgroundDrawable(new android.graphics.drawable.ColorDrawable(bg));
            win.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);
            if (Build.VERSION.SDK_INT >= 30) win.setDecorFitsSystemWindows(false);
            else win.getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_LAYOUT_STABLE | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION);
            win.setStatusBarColor(0);
            win.setNavigationBarColor(0);
            if (Build.VERSION.SDK_INT >= 30 && !Zui.dark) {
                win.getInsetsController().setSystemBarsAppearance(
                        android.view.WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS | android.view.WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS,
                        android.view.WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS | android.view.WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS);
            }
        }
        dialog = dlg;
        web = w;
        dlg.show();
        w.loadUrl(url);
    }

    /** Whether the navigation is the callback (then it is answered and not loaded). */
    static boolean intercept(String url) {
        if (url == null || prefix == null || !url.startsWith(prefix)) return false;
        close(url);
        return true;
    }

    /** Answers once and closes the page. */
    static void close(String url) {
        Dialog dlg = dialog;
        WebView w = web;
        dialog = null;
        web = null;
        prefix = null;
        if (!answered) {
            answered = true;
            done(url);
        }
        CookieManager.getInstance().flush();
        if (dlg != null) {
            try {
                dlg.dismiss();
            } catch (Exception ignored) {
            }
        }
        if (w != null) Zui.main.post(w::destroy);
    }

    static void done(String url) {
        if (Zui.started) nativeWebAuthDone(url);
    }
}
