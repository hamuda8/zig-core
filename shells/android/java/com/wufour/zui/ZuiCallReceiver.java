package com.wufour.zui;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** The "Decline" button of the ringing notification (answering opens the app instead). */
public final class ZuiCallReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        String id = intent.getStringExtra(ZuiCallService.EXTRA_ID);
        if (id != null) ZuiCallService.decline(context, id);
    }
}
