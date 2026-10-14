package com.wufour.zui;

import android.annotation.SuppressLint;
import android.app.Dialog;
import android.content.Context;
import android.content.res.ColorStateList;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Insets;
import android.graphics.Paint;
import android.graphics.Path;
import android.os.Build;
import android.text.TextUtils;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.view.WindowManager;
import android.view.animation.DecelerateInterpolator;
import android.webkit.CookieManager;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;

/**
 * fx.webAuth: a sign-in page (Wufour's) that looks like one of the app's own pages. The app's
 * top bar (its colours, a back arrow, the title; mirrored right to left), sliding in like a new
 * page; the app's background with a spinner until the first page has loaded; no zoom, link
 * menus or text-selection popups. Nothing is injected into the page. JavaScript, DOM storage
 * and cookies are on, so the site's own session is kept. A navigation to anything starting with
 * the callback prefix is not loaded: its address goes back to Zig and the page closes. The back
 * arrow, or Back on the first page, answer "cancelled" (null).
 */
final class ZuiWebAuth {
    /** The callback address that ended the sign-in, or null when the user went back. */
    static native void nativeWebAuthDone(String url);

    static Dialog dialog;
    static View page;
    static WebView web;
    static String prefix;
    static boolean answered;
    static boolean rtl;

    /** A back arrow drawn in the bar's ink (pointing to the start side). */
    static final class Arrow extends View {
        final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        final Path path = new Path();
        final boolean mirrored;

        Arrow(Context c, int ink, boolean mirrored) {
            super(c);
            this.mirrored = mirrored;
            paint.setColor(ink);
            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeCap(Paint.Cap.ROUND);
            paint.setStrokeJoin(Paint.Join.ROUND);
            paint.setStrokeWidth(2);
            // Material's arrow_back, at 24 x 24.
            path.moveTo(19, 12);
            path.lineTo(5, 12);
            path.moveTo(12, 19);
            path.lineTo(5, 12);
            path.lineTo(12, 5);
        }

        @Override
        protected void onDraw(Canvas canvas) {
            float s = Math.min(getWidth(), getHeight()) / 2 / 24f;
            canvas.save();
            canvas.translate((getWidth() - 24 * s) / 2, (getHeight() - 24 * s) / 2);
            canvas.scale(s, s);
            if (mirrored) canvas.scale(-1, 1, 12, 0);
            canvas.drawPath(path, paint);
            canvas.restore();
        }
    }

    static boolean light(int argb) {
        double l = 0.299 * Color.red(argb) + 0.587 * Color.green(argb) + 0.114 * Color.blue(argb);
        return l > 160;
    }

    @SuppressLint("SetJavaScriptEnabled")
    static void open(String url, String callbackPrefix, String title, int bar, int ink, int background, boolean rightToLeft) {
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
        rtl = rightToLeft;
        final float d = a.getResources().getDisplayMetrics().density;

        Dialog dlg = new Dialog(a, android.R.style.Theme_DeviceDefault_Light_NoActionBar) {
            @Override
            public void onBackPressed() {
                if (web != null && web.canGoBack()) web.goBack();
                else close(null);
            }
        };
        dlg.setOnCancelListener(x -> close(null));

        LinearLayout root = new LinearLayout(a);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(background);
        root.setLayoutDirection(rtl ? View.LAYOUT_DIRECTION_RTL : View.LAYOUT_DIRECTION_LTR);

        // The app's top bar: the back arrow and the title, nothing of a browser.
        LinearLayout barView = new LinearLayout(a);
        barView.setOrientation(LinearLayout.HORIZONTAL);
        barView.setGravity(Gravity.CENTER_VERTICAL);
        barView.setBackgroundColor(bar);
        barView.setElevation(2 * d);
        Arrow back = new Arrow(a, ink, rtl);
        back.setContentDescription(a.getString(android.R.string.cancel));
        TypedValue tv = new TypedValue();
        if (a.getTheme().resolveAttribute(android.R.attr.selectableItemBackgroundBorderless, tv, true)) back.setBackgroundResource(tv.resourceId);
        back.setOnClickListener(v -> close(null));
        LinearLayout.LayoutParams bp = new LinearLayout.LayoutParams((int) (48 * d), (int) (48 * d));
        bp.setMarginStart((int) (4 * d));
        barView.addView(back, bp);
        TextView t = new TextView(a);
        t.setText(title);
        t.setTextColor(ink);
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, 18);
        t.setTypeface(android.graphics.Typeface.create(android.graphics.Typeface.DEFAULT, android.graphics.Typeface.BOLD));
        t.setSingleLine(true);
        t.setEllipsize(TextUtils.TruncateAt.END);
        t.setTextAlignment(View.TEXT_ALIGNMENT_VIEW_START);
        LinearLayout.LayoutParams tp = new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1);
        tp.setMarginStart((int) (12 * d));
        tp.setMarginEnd((int) (16 * d));
        barView.addView(t, tp);
        root.addView(barView, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, (int) (56 * d)));

        // The page: hidden behind a spinner on the app's background until it has loaded.
        FrameLayout body = new FrameLayout(a);
        body.setBackgroundColor(background);
        WebView w = new WebView(a);
        w.setBackgroundColor(background);
        w.setVisibility(View.INVISIBLE);
        ProgressBar spinner = new ProgressBar(a);
        spinner.setIndeterminate(true);
        spinner.setIndeterminateTintList(ColorStateList.valueOf(ink));
        body.addView(w, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        body.addView(spinner, new FrameLayout.LayoutParams((int) (40 * d), (int) (40 * d), Gravity.CENTER));
        root.addView(body, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));

        WebSettings s = w.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setSupportMultipleWindows(false);
        s.setJavaScriptCanOpenWindowsAutomatically(false);
        // No browser feel: no zoom, no link or image menus, no selection popups (a text field
        // still gets its own long press: paste).
        s.setSupportZoom(false);
        s.setBuiltInZoomControls(false);
        s.setDisplayZoomControls(false);
        s.setTextZoom(100);
        w.setOverScrollMode(View.OVER_SCROLL_NEVER);
        w.setVerticalScrollBarEnabled(false);
        w.setHorizontalScrollBarEnabled(false);
        w.setHapticFeedbackEnabled(false);
        w.setOnLongClickListener(v -> {
            WebView.HitTestResult hit = ((WebView) v).getHitTestResult();
            return hit == null || hit.getType() != WebView.HitTestResult.EDIT_TEXT_TYPE;
        });
        CookieManager cookies = CookieManager.getInstance();
        cookies.setAcceptCookie(true);
        cookies.setAcceptThirdPartyCookies(w, true);
        w.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest req) {
                return intercept(req.getUrl().toString());
            }

            @Override
            @SuppressWarnings("deprecation")
            public boolean shouldOverrideUrlLoading(WebView view, String u) {
                return intercept(u);
            }

            @Override
            public void onPageStarted(WebView view, String u, Bitmap icon) {
                // A navigation that did not ask first (a redirect after a form post).
                if (u != null && prefix != null && u.startsWith(prefix)) {
                    view.stopLoading();
                    intercept(u);
                }
            }

            @Override
            public void onPageFinished(WebView view, String u) {
                if (view != web || view.getVisibility() == View.VISIBLE) return;
                view.setAlpha(0f);
                view.setVisibility(View.VISIBLE);
                view.animate().alpha(1f).setDuration(150).start();
                spinner.setVisibility(View.GONE);
            }
        });

        // Keep the page out of the navigation bar and the keyboard; the bar's colour goes under
        // the status bar, as on the app's own pages.
        root.setOnApplyWindowInsetsListener((v, insets) -> {
            int l, top, r, b;
            if (Build.VERSION.SDK_INT >= 30) {
                Insets i = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout() | WindowInsets.Type.ime());
                l = i.left;
                top = i.top;
                r = i.right;
                b = i.bottom;
            } else {
                l = insets.getSystemWindowInsetLeft();
                top = insets.getSystemWindowInsetTop();
                r = insets.getSystemWindowInsetRight();
                b = insets.getSystemWindowInsetBottom();
            }
            v.setPadding(l, 0, r, b);
            barView.setPadding(0, top, 0, 0);
            ViewGroup.LayoutParams lp = barView.getLayoutParams();
            lp.height = (int) (56 * d) + top;
            barView.setLayoutParams(lp);
            return insets;
        });

        dlg.requestWindowFeature(Window.FEATURE_NO_TITLE);
        dlg.setContentView(root);
        Window win = dlg.getWindow();
        if (win != null) {
            win.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT);
            win.setBackgroundDrawable(new android.graphics.drawable.ColorDrawable(Color.TRANSPARENT));
            win.setWindowAnimations(0); // the page slides itself
            win.clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
            win.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);
            if (Build.VERSION.SDK_INT >= 30) win.setDecorFitsSystemWindows(false);
            else win.getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_LAYOUT_STABLE | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION);
            win.setStatusBarColor(0);
            win.setNavigationBarColor(0);
            if (Build.VERSION.SDK_INT >= 30) {
                int mask = WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS | WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS;
                int want = (light(bar) ? WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS : 0) | (light(background) ? WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS : 0);
                win.getInsetsController().setSystemBarsAppearance(want, mask);
            }
        }
        dialog = dlg;
        page = root;
        web = w;

        // Slides in from the end side, as a new page does.
        int width = a.getResources().getDisplayMetrics().widthPixels;
        root.setTranslationX(rtl ? -width : width);
        dlg.show();
        root.animate().translationX(0).setDuration(260).setInterpolator(new DecelerateInterpolator(2f)).start();
        w.loadUrl(url);
    }

    /** Whether the navigation is the callback (then it is answered and not loaded). */
    static boolean intercept(String url) {
        if (url == null || prefix == null || !url.startsWith(prefix)) return false;
        close(url);
        return true;
    }

    /** Answers once, then slides the page away. */
    static void close(String url) {
        Dialog dlg = dialog;
        View p = page;
        WebView w = web;
        dialog = null;
        page = null;
        web = null;
        prefix = null;
        if (!answered) {
            answered = true;
            done(url);
        }
        CookieManager.getInstance().flush();
        if (w != null) w.stopLoading();
        Runnable finish = () -> {
            if (dlg != null) {
                try {
                    dlg.dismiss();
                } catch (Exception ignored) {
                }
            }
            if (w != null) w.destroy();
        };
        if (p != null && dlg != null && dlg.isShowing()) {
            int width = p.getWidth();
            p.animate().translationX(rtl ? -width : width).setDuration(220).setInterpolator(new DecelerateInterpolator()).withEndAction(finish).start();
        } else finish.run();
    }

    static void done(String url) {
        if (Zui.started) nativeWebAuthDone(url);
    }
}
