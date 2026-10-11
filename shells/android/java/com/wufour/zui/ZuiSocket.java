package com.wufour.zui;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.Socket;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import android.util.Base64;
import javax.net.ssl.SSLSocketFactory;

/**
 * A WebSocket client (RFC 6455) for zui's fx.openSocket: ws:// and wss:// (the platform's TLS),
 * text messages, pings answered, fragments joined. Reading runs on its own thread; events go
 * to the UI thread.
 */
final class ZuiSocket {
    final int id;
    private final String url;
    private Socket socket;
    private OutputStream out;
    private final Object writeLock = new Object();
    private volatile boolean closed;

    ZuiSocket(int id, String url) {
        this.id = id;
        this.url = url;
    }

    void start() {
        Thread t = new Thread(this::run, "zui-socket-" + id);
        t.setDaemon(true);
        t.start();
    }

    private void run() {
        try {
            URI u = new URI(url);
            boolean tls = "wss".equals(u.getScheme()) || "https".equals(u.getScheme());
            int port = u.getPort() > 0 ? u.getPort() : (tls ? 443 : 80);
            socket = tls ? SSLSocketFactory.getDefault().createSocket(u.getHost(), port) : new Socket(u.getHost(), port);
            socket.setTcpNoDelay(true);
            out = socket.getOutputStream();
            InputStream in = socket.getInputStream();

            byte[] nonce = new byte[16];
            new SecureRandom().nextBytes(nonce);
            String key = Base64.encodeToString(nonce, Base64.NO_WRAP);
            String path = (u.getRawPath() == null || u.getRawPath().isEmpty() ? "/" : u.getRawPath()) + (u.getRawQuery() != null ? "?" + u.getRawQuery() : "");
            String host = u.getHost() + (u.getPort() > 0 ? ":" + u.getPort() : "");
            String request = "GET " + path + " HTTP/1.1\r\nHost: " + host + "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                    + "Sec-WebSocket-Key: " + key + "\r\nSec-WebSocket-Version: 13\r\nOrigin: " + (tls ? "https://" : "http://") + host + "\r\n\r\n";
            synchronized (writeLock) {
                out.write(request.getBytes(StandardCharsets.UTF_8));
                out.flush();
            }

            // The answer must be 101 with the right Sec-WebSocket-Accept.
            String head = readHead(in);
            String expected = Base64.encodeToString(MessageDigest.getInstance("SHA-1").digest((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").getBytes(StandardCharsets.UTF_8)), Base64.NO_WRAP);
            if (!head.startsWith("HTTP/1.1 101") || !head.toLowerCase().contains("sec-websocket-accept: " + expected.toLowerCase())) throw new IOException("handshake");
            Zui.main.post(() -> Zui.nativeSocket(id, 1, null));

            ByteArrayOutputStream message = new ByteArrayOutputStream();
            while (!closed) {
                int b0 = in.read(), b1 = in.read();
                if (b0 < 0 || b1 < 0) break;
                boolean fin = (b0 & 0x80) != 0;
                int op = b0 & 0x0f;
                long len = b1 & 0x7f;
                if (len == 126) len = ((in.read() & 0xff) << 8) | (in.read() & 0xff);
                else if (len == 127) { len = 0; for (int i = 0; i < 8; i++) len = (len << 8) | (in.read() & 0xff); }
                if (len > 16 * 1024 * 1024) throw new IOException("frame too large");
                byte[] mask = null;
                if ((b1 & 0x80) != 0) { mask = new byte[4]; readFully(in, mask); }
                byte[] payload = new byte[(int) len];
                readFully(in, payload);
                if (mask != null) for (int i = 0; i < payload.length; i++) payload[i] ^= mask[i & 3];
                switch (op) {
                    case 0x0: case 0x1: case 0x2:
                        message.write(payload);
                        if (fin) {
                            final String text = new String(message.toByteArray(), StandardCharsets.UTF_8);
                            message.reset();
                            Zui.main.post(() -> Zui.nativeSocket(id, 2, text));
                        }
                        break;
                    case 0x8: // close: answer and stop
                        send(0x8, payload);
                        closed = true;
                        break;
                    case 0x9: // ping
                        send(0xA, payload);
                        break;
                    default: // pong and others
                        break;
                }
            }
        } catch (Exception ignored) {
            // the connection failed or dropped: the app hears "closed" and decides
        }
        finish();
    }

    private static String readHead(InputStream in) throws IOException {
        // Up to the blank line that ends the headers.
        ByteArrayOutputStream b = new ByteArrayOutputStream();
        int last = 0;
        while (true) {
            int c = in.read();
            if (c < 0) throw new IOException("closed during handshake");
            b.write(c);
            last = (last << 8) | c;
            if (last == 0x0d0a0d0a) return b.toString("UTF-8");
            if (b.size() > 16384) throw new IOException("handshake too long");
        }
    }

    private static void readFully(InputStream in, byte[] buf) throws IOException {
        int n = 0;
        while (n < buf.length) {
            int r = in.read(buf, n, buf.length - n);
            if (r < 0) throw new IOException("closed");
            n += r;
        }
    }

    /** A masked frame (clients must mask), from any thread. */
    void send(int op, byte[] payload) {
        if (out == null) return;
        try {
            byte[] mask = new byte[4];
            new SecureRandom().nextBytes(mask);
            ByteArrayOutputStream f = new ByteArrayOutputStream(payload.length + 14);
            f.write(0x80 | op);
            if (payload.length < 126) f.write(0x80 | payload.length);
            else if (payload.length < 65536) { f.write(0x80 | 126); f.write(payload.length >> 8); f.write(payload.length); }
            else { f.write(0x80 | 127); for (int i = 7; i >= 0; i--) f.write((int) ((long) payload.length >> (8 * i))); }
            f.write(mask);
            for (int i = 0; i < payload.length; i++) f.write(payload[i] ^ mask[i & 3]);
            synchronized (writeLock) {
                out.write(f.toByteArray());
                out.flush();
            }
        } catch (IOException ignored) {
            // the reader sees the broken connection and reports it
        }
    }

    void sendText(String text) {
        byte[] b = text.getBytes(StandardCharsets.UTF_8);
        Zui.network.execute(() -> send(0x1, b));
    }

    void close() {
        if (closed) return;
        closed = true;
        Zui.network.execute(() -> {
            send(0x8, new byte[] {0x03, (byte) 0xE8}); // 1000: normal closure
            try { if (socket != null) socket.close(); } catch (IOException ignored) { }
        });
    }

    private void finish() {
        closed = true;
        try { if (socket != null) socket.close(); } catch (IOException ignored) { }
        Zui.main.post(() -> {
            Zui.sockets.remove(id);
            Zui.nativeSocket(id, 3, null);
        });
    }
}
