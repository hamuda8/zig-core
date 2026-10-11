package com.wufour.zui;

import android.app.Activity;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.util.LruCache;
import android.view.Choreographer;
import android.view.ViewOutlineProvider;
import android.widget.ImageView;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.text.Editable;
import android.text.InputType;
import android.text.Layout;
import android.text.StaticLayout;
import android.text.TextPaint;
import android.text.TextUtils;
import android.text.TextWatcher;
import android.util.SparseArray;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowInsetsController;
import android.widget.EditText;
import android.widget.HorizontalScrollView;
import android.widget.ScrollView;
import android.widget.TextView;

/**
 * The view primitives zui's Zig code calls through JNI, and the events it gets back. Generic and
 * fixed: which views exist, where they are and what they show is decided in Zig. Sizes from Zig
 * are logical points (dp); they become pixels here.
 */
public final class Zui {
    static final int VIEW = 0, TEXT = 1, INPUT = 2, SCROLL = 3, SCROLL_X = 4, IMAGE = 5, PATH = 6;
    static final int POINTER_DOWN = 1, POINTER_MOVE = 2, POINTER_UP = 3, POINTER_CANCEL = 4;

    /** Images: decoded bitmaps in memory (1/8 of the heap), downloads on four threads. The HTTP
     *  cache installed by the activity keeps them on disk across launches. */
    static final LruCache<String, Bitmap> bitmaps = new LruCache<String, Bitmap>((int) Math.min(Integer.MAX_VALUE, Runtime.getRuntime().maxMemory() / 8)) {
        @Override
        protected int sizeOf(String key, Bitmap b) {
            return b.getByteCount();
        }
    };
    static final ExecutorService loader = Executors.newFixedThreadPool(4);
    static boolean frameRequested;
    static final int PRESS_IN = 1, PRESS_OUT = 2, PRESS = 3;

    static Activity activity;
    static ZuiLayout root;
    static float density = 1;
    static boolean started, dark;
    static float insetTop, insetRight, insetBottom, insetLeft;
    static final SparseArray<View> views = new SparseArray<>();
    static final SparseArray<Typeface> typefaces = new SparseArray<>();
    static final TextPaint paint = new TextPaint(TextPaint.ANTI_ALIAS_FLAG);

    // Implemented in Zig (libapp.so).
    static native void nativeStart(float width, float height, boolean dark, float top, float right, float bottom, float left, String lang);
    static native void nativeResize(float width, float height);
    static native void nativeInsets(float top, float right, float bottom, float left);
    static native void nativeDark(boolean dark);
    static native void nativeEvent(int id, int kind);
    static native void nativeText(int id, String text);
    static native void nativePointer(int id, int kind, int pointer, float x, float y, long timeMs);
    static native void nativeFrame();

    // ---- From the activity ----

    static void rootSized(int w, int h) {
        if (!started) {
            started = true;
            nativeStart(w / density, h / density, dark, insetTop, insetRight, insetBottom, insetLeft, java.util.Locale.getDefault().toLanguageTag());
        } else {
            nativeResize(w / density, h / density);
        }
    }

    static void insets(int top, int right, int bottom, int left) {
        insetTop = top / density;
        insetRight = right / density;
        insetBottom = bottom / density;
        insetLeft = left / density;
        if (started) root.post(() -> nativeInsets(insetTop, insetRight, insetBottom, insetLeft));
    }

    static void darkChanged(boolean isDark) {
        dark = isDark;
        if (started) nativeDark(isDark);
    }

    // ---- Called from Zig ----

    static void create(int id, int kind) {
        View v;
        switch (kind) {
            case TEXT: {
                TextView t = new TextView(activity);
                t.setIncludeFontPadding(false);
                t.setPadding(0, 0, 0, 0);
                t.setBreakStrategy(Layout.BREAK_STRATEGY_SIMPLE);
                t.setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE);
                v = t;
                break;
            }
            case INPUT: {
                EditText e = new EditText(activity);
                e.setBackground(null);
                e.setPadding(0, 0, 0, 0);
                e.setIncludeFontPadding(false);
                e.setSingleLine(true);
                e.setInputType(InputType.TYPE_CLASS_TEXT);
                e.addTextChangedListener(new TextWatcher() {
                    public void beforeTextChanged(CharSequence s, int a, int b, int c) {}
                    public void onTextChanged(CharSequence s, int a, int b, int c) {}
                    public void afterTextChanged(Editable s) {
                        if (e.getTag() == null) nativeText(id, s.toString());
                    }
                });
                v = e;
                break;
            }
            case SCROLL: {
                ScrollView s = new ScrollView(activity);
                s.setFillViewport(false);
                s.setClipToPadding(true);
                s.addView(new ZuiLayout(activity), new ViewGroup.LayoutParams(0, 0));
                v = s;
                break;
            }
            case SCROLL_X: {
                HorizontalScrollView s = new HorizontalScrollView(activity);
                s.addView(new ZuiLayout(activity), new ViewGroup.LayoutParams(0, 0));
                v = s;
                break;
            }
            case IMAGE: {
                ImageView i = new ImageView(activity);
                i.setScaleType(ImageView.ScaleType.FIT_XY);
                v = i;
                break;
            }
            case PATH:
                v = new ZuiPath(activity);
                break;
            default:
                v = new ZuiLayout(activity);
        }
        v.setLayoutParams(new ZuiLayout.Params());
        views.put(id, v);
    }

    static void destroy(int id) {
        View v = views.get(id);
        if (v == null) return;
        if (v.getParent() instanceof ViewGroup) ((ViewGroup) v.getParent()).removeView(v);
        views.remove(id);
    }

    /** The view children of `id` go into: scroll views hold a content box. */
    static ViewGroup container(int id) {
        if (id == 0) return root;
        View v = views.get(id);
        if (v instanceof ScrollView || v instanceof HorizontalScrollView) return (ViewGroup) ((ViewGroup) v).getChildAt(0);
        return (ViewGroup) v;
    }

    static void insert(int parent, int id, int index) {
        ViewGroup p = container(parent);
        View v = views.get(id);
        if (v.getParent() == p) {
            if (p.indexOfChild(v) == index) return;
            p.removeView(v);
        } else if (v.getParent() instanceof ViewGroup) {
            ((ViewGroup) v.getParent()).removeView(v);
        }
        p.addView(v, Math.min(index, p.getChildCount()));
    }

    static void frame(int id, float x, float y, float w, float h) {
        View v = views.get(id);
        ZuiLayout.Params p = (ZuiLayout.Params) v.getLayoutParams();
        // Edges are rounded, not sizes, so neighbours never gap or overlap.
        int l = Math.round(x * density), t = Math.round(y * density);
        p.x = l;
        p.y = t;
        p.width = Math.round((x + w) * density) - l;
        p.height = Math.round((y + h) * density) - t;
        v.setLayoutParams(p);
    }

    static void box(int id, int background, float radius, float borderWidth, int borderColor, float opacity) {
        View v = views.get(id);
        if (Color.alpha(background) == 0 && borderWidth <= 0) {
            v.setBackground(null);
        } else {
            GradientDrawable g = new GradientDrawable();
            g.setColor(background);
            g.setCornerRadius(radius * density);
            if (borderWidth > 0) g.setStroke(Math.max(1, Math.round(borderWidth * density)), borderColor);
            v.setBackground(g);
        }
        v.setAlpha(opacity);
    }

    static void pressable(int id, boolean on) {
        View v = views.get(id);
        if (!on) {
            v.setOnTouchListener(null);
            v.setClickable(false);
            return;
        }
        v.setClickable(true);
        v.setOnTouchListener((view, e) -> {
            switch (e.getActionMasked()) {
                case MotionEvent.ACTION_DOWN:
                    nativeEvent(id, PRESS_IN);
                    return true;
                case MotionEvent.ACTION_UP:
                    nativeEvent(id, PRESS_OUT);
                    if (e.getX() >= 0 && e.getY() >= 0 && e.getX() <= view.getWidth() && e.getY() <= view.getHeight()) {
                        view.performClick();
                        nativeEvent(id, PRESS);
                    }
                    return true;
                case MotionEvent.ACTION_CANCEL:
                    nativeEvent(id, PRESS_OUT);
                    return true;
            }
            return true;
        });
    }

    static Typeface typeface(int weight, boolean mono) {
        int key = weight * 2 + (mono ? 1 : 0);
        Typeface t = typefaces.get(key);
        if (t == null) {
            Typeface base = mono ? Typeface.MONOSPACE : Typeface.DEFAULT;
            t = Build.VERSION.SDK_INT >= 28 ? Typeface.create(base, weight, false) : Typeface.create(base, weight >= 600 ? Typeface.BOLD : Typeface.NORMAL);
            typefaces.put(key, t);
        }
        return t;
    }

    static int gravity(int align) {
        return (align == 1 ? Gravity.CENTER_HORIZONTAL : align == 2 ? Gravity.RIGHT : Gravity.LEFT) | Gravity.TOP;
    }

    static void styleText(TextView t, float size, int weight, float lineHeight, boolean mono, int color, int align) {
        t.setTextSize(TypedValue.COMPLEX_UNIT_PX, size * density);
        t.setTypeface(typeface(weight, mono));
        t.setTextColor(color);
        t.setGravity(gravity(align));
        t.setTextAlignment(View.TEXT_ALIGNMENT_GRAVITY);
        int lh = Math.round(lineHeight * density);
        if (Build.VERSION.SDK_INT >= 28) t.setLineHeight(lh);
        else t.setLineSpacing(lh - t.getPaint().getFontMetricsInt(null), 1f);
    }

    static void text(int id, String s, float size, int weight, float lineHeight, boolean mono, int maxLines, int color, int align) {
        TextView t = (TextView) views.get(id);
        t.setText(s);
        styleText(t, size, weight, lineHeight, mono, color, align);
        t.setMaxLines(maxLines > 0 ? maxLines : Integer.MAX_VALUE);
        t.setEllipsize(maxLines > 0 ? TextUtils.TruncateAt.END : null);
    }

    static void input(int id, String value, String placeholder, float size, int weight, float lineHeight, boolean mono, int color, int align) {
        EditText e = (EditText) views.get(id);
        if (!e.getText().toString().equals(value)) {
            e.setTag(Boolean.TRUE); // not a user edit
            e.setText(value);
            e.setSelection(value.length());
            e.setTag(null);
        }
        e.setHint(placeholder);
        styleText(e, size, weight, lineHeight, mono, color, align);
        e.setHintTextColor((Math.round(Color.alpha(color) * 0.45f) << 24) | (color & 0xffffff));
    }

    static void content(int id, float w, float h) {
        View c = container(id);
        ViewGroup.LayoutParams p = c.getLayoutParams();
        p.width = Math.round(w * density);
        p.height = Math.round(h * density);
        c.setLayoutParams(p);
    }

    /** End of a zui frame: lay out everything that changed in one pass. */
    static void commit() {
        root.requestLayout();
        root.invalidate();
    }

    static void transform(int id, float rotate, float tilt, float perspective) {
        View v = views.get(id);
        v.setRotation(rotate);
        v.setRotationX(tilt);
        if (perspective > 0) v.setCameraDistance(perspective * density);
    }

    static void clip(int id, boolean on) {
        View v = views.get(id);
        v.setOutlineProvider(ViewOutlineProvider.BOUNDS);
        v.setClipToOutline(on);
    }

    static void pointer(int id, boolean on) {
        View v = views.get(id);
        if (!on) {
            v.setOnTouchListener(null);
            return;
        }
        v.setOnTouchListener((view, e) -> {
            long t = e.getEventTime();
            switch (e.getActionMasked()) {
                case MotionEvent.ACTION_DOWN:
                case MotionEvent.ACTION_POINTER_DOWN: {
                    int i = e.getActionIndex();
                    nativePointer(id, POINTER_DOWN, e.getPointerId(i), e.getX(i) / density, e.getY(i) / density, t);
                    break;
                }
                case MotionEvent.ACTION_MOVE:
                    for (int i = 0; i < e.getPointerCount(); i++)
                        nativePointer(id, POINTER_MOVE, e.getPointerId(i), e.getX(i) / density, e.getY(i) / density, t);
                    break;
                case MotionEvent.ACTION_UP:
                case MotionEvent.ACTION_POINTER_UP: {
                    int i = e.getActionIndex();
                    nativePointer(id, POINTER_UP, e.getPointerId(i), e.getX(i) / density, e.getY(i) / density, t);
                    break;
                }
                case MotionEvent.ACTION_CANCEL:
                    for (int i = 0; i < e.getPointerCount(); i++)
                        nativePointer(id, POINTER_CANCEL, e.getPointerId(i), e.getX(i) / density, e.getY(i) / density, t);
                    break;
            }
            return true;
        });
    }

    static void image(int id, String url) {
        ImageView v = (ImageView) views.get(id);
        if (url.equals(v.getTag())) return;
        v.setTag(url);
        Bitmap cached = bitmaps.get(url);
        if (cached != null) {
            v.setImageBitmap(cached);
            return;
        }
        v.setImageDrawable(null);
        loader.execute(() -> {
            Bitmap b = null;
            try {
                HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
                c.setConnectTimeout(10000);
                c.setReadTimeout(15000);
                c.setUseCaches(true);
                try (InputStream in = c.getInputStream()) {
                    b = BitmapFactory.decodeStream(in);
                } finally {
                    c.disconnect();
                }
            } catch (Exception ignored) {
                // Missing tiles stay blank; the map keeps working.
            }
            if (b == null) return;
            final Bitmap bitmap = b;
            bitmaps.put(url, bitmap);
            activity.runOnUiThread(() -> {
                if (url.equals(v.getTag())) v.setImageBitmap(bitmap);
            });
        });
    }

    static void path(int id, float[] points, int color, float width, float dashOn, float dashOff, boolean round) {
        ((ZuiPath) views.get(id)).set(points, color, width, dashOn, dashOff, round, density);
    }

    static void requestFrame() {
        if (frameRequested) return;
        frameRequested = true;
        Choreographer.getInstance().postFrameCallback(time -> {
            frameRequested = false;
            nativeFrame();
        });
    }

    static void rootBackground(int argb) {
        root.setBackgroundColor(argb);
        // Dark system-bar icons on light backgrounds, light icons on dark ones.
        boolean light = Color.alpha(argb) > 0 && (0.299 * Color.red(argb) + 0.587 * Color.green(argb) + 0.114 * Color.blue(argb)) > 150;
        Window w = activity.getWindow();
        if (Build.VERSION.SDK_INT >= 30) {
            WindowInsetsController c = w.getInsetsController();
            if (c != null) {
                int mask = WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS | WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS;
                c.setSystemBarsAppearance(light ? mask : 0, mask);
            }
        } else {
            int flags = w.getDecorView().getSystemUiVisibility();
            int lightFlags = View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR | View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR;
            w.getDecorView().setSystemUiVisibility(light ? flags | lightFlags : flags & ~lightFlags);
        }
    }

    /** Size of `s` in points, packed as (float bits of width << 32) | float bits of height. */
    static long measure(String s, float size, int weight, float lineHeight, boolean mono, int maxLines, float maxWidth) {
        paint.setTextSize(size * density);
        paint.setTypeface(typeface(weight, mono));
        int avail = Float.isInfinite(maxWidth) ? 1 << 20 : Math.max(1, (int) Math.floor(maxWidth * density));
        StaticLayout layout = StaticLayout.Builder.obtain(s, 0, s.length(), paint, avail)
                .setIncludePad(false)
                .setBreakStrategy(Layout.BREAK_STRATEGY_SIMPLE)
                .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE)
                .build();
        int lines = layout.getLineCount();
        if (maxLines > 0) lines = Math.min(lines, maxLines);
        float widest = 0;
        for (int i = 0; i < lines; i++) widest = Math.max(widest, layout.getLineWidth(i));
        // One spare pixel so rounding the frame to pixels never forces an extra line break.
        float w = s.isEmpty() ? 0 : (float) (Math.ceil(widest) + 1) / density;
        float h = lines * Math.round(lineHeight * density) / density;
        return ((long) Float.floatToRawIntBits(w) << 32) | (Float.floatToRawIntBits(h) & 0xffffffffL);
    }
}
