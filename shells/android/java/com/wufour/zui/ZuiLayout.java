package com.wufour.zui;

import android.content.Context;
import android.view.View;
import android.view.ViewGroup;

/** A container that puts each child exactly at the frame zui computed. It never decides sizes itself. */
public final class ZuiLayout extends ViewGroup {
    /** Frame in pixels, relative to the parent. */
    public static final class Params extends ViewGroup.LayoutParams {
        public int x, y;

        public Params() {
            super(0, 0);
        }
    }

    boolean isRoot;

    public ZuiLayout(Context context) {
        super(context);
        setClipChildren(false);
    }

    @Override
    protected void onMeasure(int widthSpec, int heightSpec) {
        for (int i = 0; i < getChildCount(); i++) {
            View c = getChildAt(i);
            ViewGroup.LayoutParams p = c.getLayoutParams();
            c.measure(MeasureSpec.makeMeasureSpec(Math.max(0, p.width), MeasureSpec.EXACTLY),
                    MeasureSpec.makeMeasureSpec(Math.max(0, p.height), MeasureSpec.EXACTLY));
        }
        // The root fills the window; a scroll content box has the size zui gave it.
        ViewGroup.LayoutParams own = getLayoutParams();
        int w = MeasureSpec.getMode(widthSpec) == MeasureSpec.EXACTLY || own == null || own.width < 0 ? MeasureSpec.getSize(widthSpec) : own.width;
        int h = MeasureSpec.getMode(heightSpec) == MeasureSpec.EXACTLY || own == null || own.height < 0 ? MeasureSpec.getSize(heightSpec) : own.height;
        setMeasuredDimension(w, h);
    }

    @Override
    protected void onLayout(boolean changed, int l, int t, int r, int b) {
        for (int i = 0; i < getChildCount(); i++) {
            View c = getChildAt(i);
            ViewGroup.LayoutParams lp = c.getLayoutParams();
            int x = 0, y = 0;
            if (lp instanceof Params) {
                x = ((Params) lp).x;
                y = ((Params) lp).y;
            }
            c.layout(x, y, x + c.getMeasuredWidth(), y + c.getMeasuredHeight());
        }
    }

    @Override
    protected void onSizeChanged(int w, int h, int oldw, int oldh) {
        super.onSizeChanged(w, h, oldw, oldh);
        if (isRoot) Zui.rootSized(w, h);
    }

    @Override
    protected ViewGroup.LayoutParams generateDefaultLayoutParams() {
        return new Params();
    }

    @Override
    protected boolean checkLayoutParams(ViewGroup.LayoutParams p) {
        return true;
    }
}
