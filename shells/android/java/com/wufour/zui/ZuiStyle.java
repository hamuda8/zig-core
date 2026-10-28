package com.wufour.zui;

import android.animation.ObjectAnimator;
import android.animation.ValueAnimator;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.ColorFilter;
import android.graphics.LinearGradient;
import android.graphics.Outline;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.PixelFormat;
import android.graphics.Rect;
import android.graphics.RectF;
import android.graphics.Shader;
import android.graphics.Typeface;
import android.graphics.drawable.Drawable;
import android.os.Build;
import android.text.Layout;
import android.text.SpannableString;
import android.text.Spanned;
import android.text.StaticLayout;
import android.text.TextPaint;
import android.text.TextUtils;
import android.text.style.ForegroundColorSpan;
import android.text.style.MetricAffectingSpan;
import android.text.style.StrikethroughSpan;
import android.text.style.UnderlineSpan;
import android.util.SparseArray;
import android.view.HapticFeedbackConstants;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.ViewTreeObserver;
import android.view.animation.LinearInterpolator;
import android.view.animation.PathInterpolator;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.ScrollView;
import android.widget.TextView;

/**
 * zui's styling and interaction on Android, drawn to look as the web shim draws it: rich text
 * with links, pictures from memory, decorations (per-corner radii, per-side borders, a shadow, a
 * gradient), transitions, spinners and scroll control. Sizes from Zig are dp.
 */
final class ZuiStyle {
    static native void nativeSpan(int id, int index);
    static native void nativeScroll(int id, float offset);

    // ---- Rich text ----

    /** A run's typeface (weight, italic, monospace). */
    static final class FontSpan extends MetricAffectingSpan {
        final Typeface face;

        FontSpan(Typeface face) {
            this.face = face;
        }

        @Override
        public void updateDrawState(TextPaint p) {
            p.setTypeface(face);
        }

        @Override
        public void updateMeasureState(TextPaint p) {
            p.setTypeface(face);
        }
    }

    /** A link run: its number among the text's links. */
    static final class LinkSpan {
        final int index;

        LinkSpan(int index) {
            this.index = index;
        }
    }

    /** A run's typeface: the text's face (Zui.FACE_*) at a weight, slanted by Android when the
     *  run is italic (our files have no italics). */
    static Typeface face(int weight, boolean italic, int which) {
        Typeface base = Zui.typeface(weight, which);
        if (!italic) return base;
        return Build.VERSION.SDK_INT >= 28 ? Typeface.create(base, Math.max(1, Math.min(1000, weight)), true) : Typeface.create(base, Typeface.ITALIC);
    }

    /** Spans come as 5 ints each: start, end (UTF-16), flags (bold 1, italic 2, mono 4,
     *  underline 8, strike 16), colour, link (-1: none). `which` is the text's face. */
    static CharSequence spanned(String s, int[] spans, int weight, int which) {
        if (spans == null || spans.length == 0) return s;
        SpannableString out = new SpannableString(s);
        for (int k = 0; k + 4 < spans.length; k += 5) {
            int a = Math.max(0, Math.min(s.length(), spans[k])), b = Math.max(a, Math.min(s.length(), spans[k + 1]));
            int flags = spans[k + 2], color = spans[k + 3], link = spans[k + 4];
            if (a == b) continue;
            boolean bold = (flags & 1) != 0, italic = (flags & 2) != 0, m = (flags & 4) != 0;
            if (bold || italic || m) out.setSpan(new FontSpan(face(bold ? Math.max(weight, 700) : weight, italic, m ? Zui.FACE_MONO : which)), a, b, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
            if ((flags & 8) != 0) out.setSpan(new UnderlineSpan(), a, b, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
            if ((flags & 16) != 0) out.setSpan(new StrikethroughSpan(), a, b, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
            if ((color >>> 24) != 0) out.setSpan(new ForegroundColorSpan(color), a, b, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
            if (link >= 0) out.setSpan(new LinkSpan(link), a, b, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        }
        return out;
    }

    static void richText(int id, String s, int[] spans, float size, int weight, float lineHeight, int face, int maxLines, int color, int align, float letter, boolean selectable) {
        View v = Zui.views.get(id);
        if (!(v instanceof TextView)) return;
        TextView t = (TextView) v;
        CharSequence text = spanned(s, spans, weight, face);
        Zui.styleText(t, size, weight, lineHeight, face, color, align);
        t.setLetterSpacing(size > 0 ? letter / size : 0);
        t.setMaxLines(maxLines > 0 ? maxLines : Integer.MAX_VALUE);
        t.setEllipsize(maxLines > 0 && !selectable ? TextUtils.TruncateAt.END : null);
        if (selectable != t.isTextSelectable()) t.setTextIsSelectable(selectable);
        t.setText(text, TextView.BufferType.SPANNABLE);
        boolean links = false;
        if (text instanceof Spanned) links = ((Spanned) text).getSpans(0, text.length(), LinkSpan.class).length > 0;
        // Taps on a link are the link's; anywhere else they reach the views around (a pressable
        // row) or the selection.
        t.setOnTouchListener(links ? ZuiStyle::linkTouch : null);
    }

    static int linkAt(TextView t, MotionEvent e) {
        Layout l = t.getLayout();
        if (l == null || !(t.getText() instanceof Spanned)) return -1;
        int x = (int) e.getX() - t.getTotalPaddingLeft() + t.getScrollX();
        int y = (int) e.getY() - t.getTotalPaddingTop() + t.getScrollY();
        int line = l.getLineForVertical(y);
        if (x < l.getLineLeft(line) || x > l.getLineRight(line)) return -1;
        int off = l.getOffsetForHorizontal(line, x);
        LinkSpan[] found = ((Spanned) t.getText()).getSpans(off, off, LinkSpan.class);
        for (LinkSpan sp : found) {
            Spanned sd = (Spanned) t.getText();
            if (off >= sd.getSpanStart(sp) && off < sd.getSpanEnd(sp)) return sp.index;
        }
        return -1;
    }

    static boolean linkTouch(View v, MotionEvent e) {
        TextView t = (TextView) v;
        int id = Zui.views.indexOfValue(v) >= 0 ? Zui.views.keyAt(Zui.views.indexOfValue(v)) : 0;
        switch (e.getActionMasked()) {
            case MotionEvent.ACTION_DOWN:
                return linkAt(t, e) >= 0;
            case MotionEvent.ACTION_UP: {
                int link = linkAt(t, e);
                if (link >= 0 && id != 0) nativeSpan(id, link);
                return true;
            }
            default:
                return true;
        }
    }

    static long measureRich(String s, int[] spans, float size, int weight, float lineHeight, int face, int maxLines, float maxWidth, float letter) {
        float density = Zui.density;
        TextPaint p = new TextPaint(TextPaint.ANTI_ALIAS_FLAG);
        p.setTextSize(size * density);
        p.setTypeface(Zui.typeface(weight, face));
        p.setLetterSpacing(size > 0 ? letter / size : 0);
        CharSequence text = spanned(s, spans, weight, face);
        int avail = Float.isInfinite(maxWidth) ? 1 << 20 : Math.max(1, (int) Math.floor(maxWidth * density));
        StaticLayout layout = StaticLayout.Builder.obtain(text, 0, text.length(), p, avail)
                .setIncludePad(false)
                .setBreakStrategy(Layout.BREAK_STRATEGY_SIMPLE)
                .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE)
                .build();
        int lines = layout.getLineCount();
        if (maxLines > 0) lines = Math.min(lines, maxLines);
        float widest = 0;
        for (int i = 0; i < lines; i++) widest = Math.max(widest, layout.getLineWidth(i));
        float w = s.isEmpty() ? 0 : (float) (Math.ceil(widest) + 1) / density;
        float h = lines * Math.round(lineHeight * density) / density;
        return ((long) Float.floatToRawIntBits(w) << 32) | (Float.floatToRawIntBits(h) & 0xffffffffL);
    }

    // ---- Pictures from memory ----

    static void imageBytes(int id, String key, byte[] bytes) {
        View v = Zui.views.get(id);
        if (!(v instanceof ImageView)) return;
        ImageView iv = (ImageView) v;
        final String tag = "\nmem:" + key;
        if (tag.equals(iv.getTag())) return;
        iv.setTag(tag);
        Bitmap cached = Zui.bitmaps.get(tag);
        if (cached != null) {
            iv.setImageBitmap(cached);
            return;
        }
        iv.setImageDrawable(null);
        Zui.loader.execute(() -> {
            Bitmap b = null;
            try {
                b = BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
            } catch (Throwable ignored) {
            }
            final Bitmap bitmap = b;
            if (bitmap != null) Zui.bitmaps.put(tag, bitmap);
            Zui.main.post(() -> {
                if (bitmap != null && tag.equals(iv.getTag())) iv.setImageBitmap(bitmap);
            });
        });
    }

    static void imageFit(int id, int fit) {
        View v = Zui.views.get(id);
        if (!(v instanceof ImageView)) return;
        ImageView iv = (ImageView) v;
        iv.setScaleType(fit == 1 ? ImageView.ScaleType.CENTER_CROP : fit == 2 ? ImageView.ScaleType.FIT_CENTER : ImageView.ScaleType.FIT_XY);
        iv.setCropToPadding(true);
        iv.setOutlineProvider(ROUND);
        iv.setClipToOutline(true);
    }

    // ---- Rounded outlines: pictures and `clip` are cut round, as CSS cuts them ----

    static final int R_RADIUS = 0x7f5a0003;

    /** The view's box radius (Zui.box draws it; this is for cutting). */
    static final android.view.ViewOutlineProvider ROUND = new android.view.ViewOutlineProvider() {
        @Override
        public void getOutline(View v, Outline o) {
            Object r = v.getTag(R_RADIUS);
            o.setRoundRect(0, 0, v.getWidth(), v.getHeight(), r instanceof Float ? (Float) r : 0f);
        }
    };

    static void radius(int id, float r) {
        View v = Zui.views.get(id);
        if (v == null) return;
        Object was = v.getTag(R_RADIUS);
        float px = r * Zui.density;
        if (was instanceof Float && (Float) was == px) return;
        v.setTag(R_RADIUS, px);
        if (v instanceof ImageView && px > 0) {
            v.setOutlineProvider(ROUND);
            v.setClipToOutline(true);
        }
        v.invalidateOutline();
    }

    // ---- Decorations ----

    /** What CSS draws for a box: shadow, background and gradient in the rounded shape, borders
     *  over it (each side up to the diagonals between its corners). */
    static final class Box extends Drawable {
        final float density = Zui.density;
        int background, shadowColor;
        float[] radii = new float[4], widths = new float[4], shadow = new float[3], stopsAt;
        int[] colors = new int[4], stopColors;
        float angle;
        boolean dashed;
        final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        final Path path = new Path(), inner = new Path(), side = new Path();

        /** Corner radii (top-left, top-right, bottom-right, bottom-left) as Path's 8 values,
         *  scaled down as CSS does when they do not fit. */
        float[] corner8(RectF r, float[] rad, float dl, float dt, float dr, float db) {
            float[] o = new float[8];
            float k = 1;
            float[] sums = {rad[0] + rad[1], rad[3] + rad[2], rad[0] + rad[3], rad[1] + rad[2]};
            float[] lens = {r.width() + dl + dr, r.width() + dl + dr, r.height() + dt + db, r.height() + dt + db};
            for (int i = 0; i < 4; i++) if (sums[i] > 0 && lens[i] < sums[i]) k = Math.min(k, lens[i] / sums[i]);
            float[] ins = {dl, dt, dr, dt, dr, db, dl, db};
            for (int c = 0; c < 4; c++) {
                o[2 * c] = Math.max(0, rad[c] * k * density - ins[2 * c]);
                o[2 * c + 1] = Math.max(0, rad[c] * k * density - ins[2 * c + 1]);
            }
            return o;
        }

        @Override
        public void draw(Canvas canvas) {
            Rect b = getBounds();
            RectF r = new RectF(b);
            path.reset();
            path.addRoundRect(r, corner8(r, radii, 0, 0, 0, 0), Path.Direction.CW);
            if ((shadowColor >>> 24) != 0) {
                // Outside the box only, as box-shadow; CSS blur B is a Gaussian of sigma B/2,
                // and Skia turns a shadow radius R into sigma 0.57735 R + 0.5.
                float sigma = shadow[2] * density / 2;
                float radius = sigma > 0.5f ? (sigma - 0.5f) / 0.57735f : 0.01f;
                paint.reset();
                paint.setAntiAlias(true);
                paint.setColor(shadowColor);
                paint.setShadowLayer(radius, shadow[0] * density, shadow[1] * density, shadowColor);
                canvas.save();
                canvas.clipOutPath(path);
                canvas.drawPath(path, paint);
                canvas.restore();
            }
            paint.reset();
            paint.setAntiAlias(true);
            if ((background >>> 24) != 0) {
                paint.setColor(background);
                canvas.drawPath(path, paint);
            }
            if (stopColors != null && stopColors.length > 0) {
                // The CSS gradient line: through the centre at `angle`, as long as the box's
                // projection on it.
                double a = Math.toRadians(angle);
                float dx = (float) Math.sin(a), dy = (float) -Math.cos(a);
                float len = Math.abs(r.width() * dx) + Math.abs(r.height() * dy);
                float cx = r.centerX(), cy = r.centerY();
                int[] cs = stopColors;
                float[] at = stopsAt;
                if (cs.length == 1) {
                    cs = new int[] {cs[0], cs[0]};
                    at = new float[] {0, 1};
                }
                paint.setShader(new LinearGradient(cx - dx * len / 2, cy - dy * len / 2, cx + dx * len / 2, cy + dy * len / 2, cs, at, Shader.TileMode.CLAMP));
                canvas.drawPath(path, paint);
                paint.setShader(null);
            }
            float t = widths[0] * density, rt = widths[1] * density, bt = widths[2] * density, l = widths[3] * density;
            if (t > 0 || rt > 0 || bt > 0 || l > 0) {
                inner.reset();
                RectF in = new RectF(r.left + l, r.top + t, r.right - rt, r.bottom - bt);
                if (in.width() > 0 && in.height() > 0) inner.addRoundRect(in, corner8(r, radii, l, t, rt, bt), Path.Direction.CW);
                float[][] quads = {
                    {r.left, r.top, r.right, r.top, r.right - rt, r.top + t, r.left + l, r.top + t},
                    {r.right, r.top, r.right, r.bottom, r.right - rt, r.bottom - bt, r.right - rt, r.top + t},
                    {r.right, r.bottom, r.left, r.bottom, r.left + l, r.bottom - bt, r.right - rt, r.bottom - bt},
                    {r.left, r.bottom, r.left, r.top, r.left + l, r.top + t, r.left + l, r.bottom - bt},
                };
                for (int s = 0; s < 4; s++) {
                    if (widths[s] <= 0 || (colors[s] >>> 24) == 0) continue;
                    float[] q = quads[s];
                    // The quad from the outer corners to the inner ones, pushed out past the
                    // round corners.
                    // Outer corners pushed far out along the diagonals to their inner corners.
                    side.reset();
                    for (int k = 0; k < 4; k++) {
                        float px = q[2 * k], py = q[2 * k + 1];
                        if (k < 2) {
                            px += (px - q[2 * (3 - k)]) * 100;
                            py += (py - q[2 * (3 - k) + 1]) * 100;
                        }
                        if (k == 0) side.moveTo(px, py); else side.lineTo(px, py);
                    }
                    side.close();
                    canvas.save();
                    canvas.clipPath(side);
                    canvas.clipPath(path);
                    if (!inner.isEmpty()) canvas.clipOutPath(inner);
                    paint.setColor(colors[s]);
                    if (dashed) {
                        // The side's dashes: the box's outline drawn as a dashed line of this
                        // side's width along the middle of the border (dashes of 3 widths, as
                        // browsers draw thin dashed borders), cut to the side.
                        float sw = widths[s] * density;
                        RectF mid = new RectF(r.left + sw / 2, r.top + sw / 2, r.right - sw / 2, r.bottom - sw / 2);
                        Path line = new Path();
                        line.addRoundRect(mid, corner8(r, radii, sw / 2, sw / 2, sw / 2, sw / 2), Path.Direction.CW);
                        paint.setStyle(Paint.Style.STROKE);
                        paint.setStrokeWidth(sw);
                        paint.setPathEffect(new android.graphics.DashPathEffect(new float[] {3 * sw, 3 * sw}, 0));
                        canvas.drawPath(line, paint);
                        paint.setPathEffect(null);
                        paint.setStyle(Paint.Style.FILL);
                    } else {
                        canvas.drawRect(r, paint);
                    }
                    canvas.restore();
                }
            }
        }

        @Override
        public void getOutline(Outline o) {
            Rect b = getBounds();
            if (radii[0] == radii[1] && radii[1] == radii[2] && radii[2] == radii[3]) o.setRoundRect(b, radii[0] * density);
            else o.setRect(b);
        }

        @Override
        public void setAlpha(int a) {}

        @Override
        public void setColorFilter(ColorFilter f) {}

        @Override
        public int getOpacity() {
            return PixelFormat.TRANSLUCENT;
        }
    }

    /** f: radii 4, widths 4, shadow 3, angle, stop positions; c: border colours 4, shadow colour,
     *  stop colours. Called after Zui.box when the box is more than one colour, radius and border. */
    static void decor(int id, int background, float[] f, int[] c) {
        View v = Zui.views.get(id);
        if (v == null) return;
        Box d = new Box();
        d.background = background;
        System.arraycopy(f, 0, d.radii, 0, 4);
        System.arraycopy(f, 4, d.widths, 0, 4);
        System.arraycopy(f, 8, d.shadow, 0, 3);
        d.angle = f[11];
        d.dashed = f[12] != 0;
        System.arraycopy(c, 0, d.colors, 0, 4);
        d.shadowColor = c[4];
        int n = c.length - 5;
        if (n > 0) {
            d.stopColors = new int[n];
            d.stopsAt = new float[n];
            System.arraycopy(c, 5, d.stopColors, 0, n);
            System.arraycopy(f, 13, d.stopsAt, 0, n);
        }
        v.setBackground(d);
        // A shadow draws outside the view: the parents let it.
        if ((d.shadowColor >>> 24) != 0) v.post(() -> {
            if (v.getParent() instanceof ViewGroup) ((ViewGroup) v.getParent()).setClipChildren(false);
        });
    }

    // ---- Transitions and spinners ----

    static final SparseArray<float[]> transitions = new SparseArray<>();

    static void transition(int id, int ms, float x1, float y1, float x2, float y2) {
        if (ms <= 0) transitions.remove(id); else transitions.put(id, new float[] {ms, x1, y1, x2, y2});
    }

    static ValueAnimator animator(float[] t) {
        ValueAnimator a = ValueAnimator.ofFloat(0, 1);
        a.setDuration((long) t[0]);
        a.setInterpolator(new PathInterpolator(t[1], t[2], t[3], t[4]));
        return a;
    }

    /** A frame change, animated when the view has a transition and was already placed. */
    static boolean frame(int id, float x, float y, float w, float h) {
        float[] t = transitions.get(id);
        View v = Zui.views.get(id);
        if (t == null || v == null || !(v.getLayoutParams() instanceof ZuiLayout.Params)) return false;
        ZuiLayout.Params p = (ZuiLayout.Params) v.getLayoutParams();
        if (p.width <= 0 && p.height <= 0) return false;
        float d = Zui.density;
        final int x0 = p.x, y0 = p.y, w0 = p.width, h0 = p.height;
        final int x1 = Math.round(x * d), y1 = Math.round(y * d), w1 = Math.round((x + w) * d) - x1, h1 = Math.round((y + h) * d) - y1;
        Object old = v.getTag(R_ANIM);
        if (old instanceof ValueAnimator) ((ValueAnimator) old).cancel();
        ValueAnimator a = animator(t);
        a.addUpdateListener(an -> {
            float k = (float) an.getAnimatedValue();
            p.x = Math.round(x0 + (x1 - x0) * k);
            p.y = Math.round(y0 + (y1 - y0) * k);
            p.width = Math.round(w0 + (w1 - w0) * k);
            p.height = Math.round(h0 + (h1 - h0) * k);
            v.setLayoutParams(p);
        });
        v.setTag(R_ANIM, a);
        a.start();
        return true;
    }

    static final int R_ANIM = 0x7f5a0001, R_ALPHA = 0x7f5a0002;

    /** Opacity and rotation, from what they were to what Zui just set, when animated. */
    static void alphaTo(int id, float target) {
        View v = Zui.views.get(id);
        float[] t = transitions.get(id);
        Object was = v == null ? null : v.getTag(R_ALPHA);
        if (v != null) v.setTag(R_ALPHA, target);
        if (v == null || t == null || !(was instanceof Float) || (Float) was == target) return;
        v.setAlpha((Float) was);
        v.animate().alpha(target).setDuration((long) t[0]).setInterpolator(new PathInterpolator(t[1], t[2], t[3], t[4])).start();
    }

    static void rotateFrom(int id, float from) {
        View v = Zui.views.get(id);
        float[] t = transitions.get(id);
        if (v == null || t == null) return;
        float target = v.getRotation();
        if (target == from) return;
        v.setRotation(from);
        v.animate().rotation(target).setDuration((long) t[0]).setInterpolator(new PathInterpolator(t[1], t[2], t[3], t[4])).start();
    }

    static final SparseArray<ObjectAnimator> spins = new SparseArray<>();

    static void spin(int id, int ms) {
        ObjectAnimator old = spins.get(id);
        if (old != null) old.cancel();
        spins.remove(id);
        View v = Zui.views.get(id);
        if (v == null || ms <= 0) return;
        ObjectAnimator a = ObjectAnimator.ofFloat(v, View.ROTATION, 0, 360);
        a.setDuration(ms);
        a.setRepeatCount(ValueAnimator.INFINITE);
        a.setInterpolator(new LinearInterpolator());
        a.start();
        spins.put(id, a);
    }

    /** A box's label: what TalkBack says. */
    static void label(int id, String s) {
        View v = Zui.views.get(id);
        if (v != null) v.setContentDescription(s.isEmpty() ? null : s);
    }

    /** An icon button held down: its label for a moment. */
    static void showLabel(int id, String s) {
        if (Zui.activity != null) android.widget.Toast.makeText(Zui.activity, s, android.widget.Toast.LENGTH_SHORT).show();
    }

    static void haptic() {
        if (Zui.root != null) Zui.root.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS);
    }

    // ---- Scroll views ----

    static void watchScroll(int id) {
        View v = Zui.views.get(id);
        if (v == null) return;
        // What scrolls stays inside the view (its parents let children draw outside).
        v.setOutlineProvider(android.view.ViewOutlineProvider.BOUNDS);
        v.setClipToOutline(true);
        final boolean horizontal = v instanceof HorizontalScrollView;
        v.setOnScrollChangeListener((view, x, y, ox, oy) -> nativeScroll(id, (horizontal ? x : y) / Zui.density));
    }

    static void scrollTo(int id, float offset, boolean animated) {
        View v = Zui.views.get(id);
        if (v == null) return;
        Runnable go = () -> {
            int px = Math.round(offset * Zui.density);
            if (v instanceof HorizontalScrollView) {
                if (animated) ((HorizontalScrollView) v).smoothScrollTo(px, 0); else v.scrollTo(px, 0);
            } else if (v instanceof ScrollView) {
                if (animated) ((ScrollView) v).smoothScrollTo(0, px); else v.scrollTo(0, px);
            }
        };
        View content = v instanceof ViewGroup && ((ViewGroup) v).getChildCount() > 0 ? ((ViewGroup) v).getChildAt(0) : null;
        // A new content size is only known after the next layout pass: scroll after it.
        if (v.isLayoutRequested() || (content != null && content.isLayoutRequested())) {
            v.getViewTreeObserver().addOnGlobalLayoutListener(new ViewTreeObserver.OnGlobalLayoutListener() {
                @Override
                public void onGlobalLayout() {
                    v.getViewTreeObserver().removeOnGlobalLayoutListener(this);
                    go.run();
                }
            });
        } else {
            go.run();
        }
    }
}
