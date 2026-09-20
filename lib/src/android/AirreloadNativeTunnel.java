package dev.airreload.runtime;

import android.content.Context;
import android.os.Build;
import android.util.Base64;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.Charset;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.security.cert.CertificateException;
import java.security.cert.X509Certificate;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Iterator;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLParameters;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;
import org.json.JSONObject;

/**
 * Phone-side Airreload tunnel. Keep the protocol numbers and frame operations
 * aligned with cli/lib/src/tunnel.dart.
 *
 * This runs on a JVM daemon thread so Flutter hot restart can replace the Dart
 * isolate without destroying the authenticated WSS connection or the multiplexed
 * VM-service sockets Flutter tooling is already using.
 */
public final class AirreloadNativeTunnel {
  private static final String VM_FILE = "airreload-vm.json";
  private static final Charset UTF8 = Charset.forName("UTF-8");
  private static final int MAX_SOCKETS = 64;
  private static final int MAX_FRAME_CHARS = 100000;
  private static final int CHUNK_SIZE = 32768;
  private static final int CONNECT_TIMEOUT_MS = 8000;
  private static final int HANDSHAKE_TIMEOUT_MS = 10000;
  private static final int VM_CONNECT_TIMEOUT_MS = 5000;
  private static final int PING_INTERVAL_MS = 10000;
  private static final SecureRandom RANDOM = new SecureRandom();

  private static boolean started;

  private AirreloadNativeTunnel() {}

  public static synchronized void start(Context context) {
    if (started || context == null) {
      return;
    }
    started = true;
    final Context app = context.getApplicationContext();
    // ContentProvider startup precedes Flutter's new engine. Disk caches can
    // still contain the VM port and auth path belonging to the dead process.
    clearVmCache(vmCacheDirectories(app));
    Thread thread =
        new Thread(
            new Runnable() {
              @Override
              public void run() {
                connectForever(app);
              }
            },
            "airreload-tunnel");
    thread.setDaemon(true);
    thread.start();
  }

  private static void connectForever(Context context) {
    while (true) {
      try {
        SessionConfig config = SessionConfig.load(context);
        VmEndpoint vm = discoverVm(context);
        if (config != null && vm != null) {
          new Session(config, vm).run();
        }
      } catch (Exception ignored) {
        // Connection failures must not terminate the app.
      }
      try {
        Thread.sleep(2000);
      } catch (InterruptedException interrupted) {
        Thread.currentThread().interrupt();
        return;
      }
    }
  }

  private static VmEndpoint discoverVm(Context context) {
    VmEndpoint fromEngine = VmEndpoint.parse(vmServiceUriFromEngine());
    if (fromEngine != null) {
      return fromEngine;
    }
    File[] dirs = vmCacheDirectories(context);
    for (int i = 0; i < dirs.length; i++) {
      File dir = dirs[i];
      if (dir == null) {
        continue;
      }
      File file = new File(dir, VM_FILE);
      if (!file.isFile()) {
        continue;
      }
      VmEndpoint parsed = VmEndpoint.parse(readFile(file));
      if (parsed != null) {
        return parsed;
      }
    }
    return null;
  }

  private static File[] vmCacheDirectories(Context context) {
    return new File[] {
      context.getCodeCacheDir(),
      context.getCacheDir(),
      context.getFilesDir(),
      new File(context.getApplicationInfo().dataDir)
    };
  }

  static void clearVmCache(File[] dirs) {
    for (File dir : dirs) {
      if (dir == null) continue;
      File endpoint = new File(dir, VM_FILE);
      if (endpoint.isFile()) endpoint.delete();
    }
  }

  private static String vmServiceUriFromEngine() {
    try {
      Class<?> jni = Class.forName("io.flutter.embedding.engine.FlutterJNI");
      Object value = jni.getMethod("getVMServiceUri").invoke(null);
      return value instanceof String ? (String) value : null;
    } catch (Exception ignored) {
      return null;
    }
  }

  private static String readFile(File file) {
    FileInputStream input = null;
    try {
      input = new FileInputStream(file);
      byte[] data = readAll(input, (int) file.length());
      return new String(data, UTF8);
    } catch (Exception ignored) {
      return null;
    } finally {
      closeQuietly(input);
    }
  }

  private static byte[] readAll(InputStream input, int hint) throws IOException {
    ByteArrayOutputStream output = new ByteArrayOutputStream(Math.max(hint, 64));
    byte[] buffer = new byte[4096];
    int read;
    while ((read = input.read(buffer)) >= 0) {
      output.write(buffer, 0, read);
    }
    return output.toByteArray();
  }

  private static void closeQuietly(InputStream input) {
    if (input == null) {
      return;
    }
    try {
      input.close();
    } catch (IOException ignored) {
    }
  }

  private static final class SessionConfig {
    final String host;
    final int port;
    final String token;
    final byte[] pin;

    SessionConfig(String host, int port, String token, byte[] pin) {
      this.host = host;
      this.port = port;
      this.token = token;
      this.pin = pin;
    }

    static SessionConfig load(Context context) throws Exception {
      InputStream input = context.getAssets().open("airreload-session.json");
      try {
        JSONObject json = new JSONObject(new String(readAll(input, 512), UTF8));
        String host = json.getString("host");
        int port = json.getInt("port");
        String token = json.getString("token");
        byte[] pin = Base64.decode(json.getString("certificatePin"), Base64.DEFAULT);
        if (host == null
            || host.isEmpty()
            || port < 1
            || port > 65535
            || token == null
            || token.isEmpty()
            || pin == null
            || pin.length == 0) {
          return null;
        }
        return new SessionConfig(host, port, token, pin);
      } finally {
        closeQuietly(input);
      }
    }
  }

  private static final class VmEndpoint {
    final InetAddress address;
    final int port;
    final String path;

    VmEndpoint(InetAddress address, int port, String path) {
      this.address = address;
      this.port = port;
      this.path = path;
    }

    static VmEndpoint parse(String raw) {
      if (raw == null || raw.isEmpty()) {
        return null;
      }
      try {
        if (raw.trim().startsWith("{")) {
          JSONObject json = new JSONObject(raw);
          return fromParts(json.getString("host"), json.getInt("port"), json.getString("path"));
        }
        java.net.URI uri = java.net.URI.create(raw.trim());
        return fromParts(uri.getHost(), uri.getPort(), uri.getPath());
      } catch (Exception ignored) {
        return null;
      }
    }

    static VmEndpoint fromParts(String host, int port, String path) throws Exception {
      InetAddress address = InetAddress.getByName(host);
      if (address == null
          || !address.isLoopbackAddress()
          || port < 1
          || port > 65535
          || path == null
          || !path.matches("^/[A-Za-z0-9_=-]+/$")) {
        return null;
      }
      return new VmEndpoint(address, port, path);
    }
  }

  private static final class Session {
    private final SessionConfig config;
    private final VmEndpoint vm;
    private final Map<Integer, Socket> sockets = new HashMap<Integer, Socket>();
    private final Set<Integer> reserved = new HashSet<Integer>();
    private final Object writeLock = new Object();
    private final ExecutorService io = Executors.newCachedThreadPool();
    private SSLSocket link;
    private DataInputStream input;
    private OutputStream output;
    private volatile boolean closed;

    Session(SessionConfig config, VmEndpoint vm) {
      this.config = config;
      this.vm = vm;
    }

    void run() throws Exception {
      SSLSocket socket = openTls();
      link = socket;
      input = new DataInputStream(socket.getInputStream());
      output = socket.getOutputStream();
      handshake();
      Thread ping =
          new Thread(
              new Runnable() {
                @Override
                public void run() {
                  pingLoop();
                }
              },
              "airreload-ping");
      ping.setDaemon(true);
      ping.start();
      try {
        readLoop();
      } finally {
        close();
      }
    }

    private SSLSocket openTls() throws Exception {
      final byte[] pin = config.pin;
      TrustManager trust =
          new X509TrustManager() {
            @Override
            public void checkClientTrusted(X509Certificate[] chain, String authType) {}

            @Override
            public void checkServerTrusted(X509Certificate[] chain, String authType)
                throws CertificateException {
              if (chain == null
                  || chain.length == 0
                  || !MessageDigest.isEqual(chain[0].getEncoded(), pin)) {
                throw new CertificateException("Airreload certificate pin mismatch");
              }
            }

            @Override
            public X509Certificate[] getAcceptedIssuers() {
              return new X509Certificate[0];
            }
          };
      SSLContext context = SSLContext.getInstance("TLS");
      context.init(null, new TrustManager[] {trust}, RANDOM);
      SSLSocket socket = (SSLSocket) context.getSocketFactory().createSocket();
      socket.setUseClientMode(true);
      socket.setTcpNoDelay(true);
      if (Build.VERSION.SDK_INT >= 24) {
        SSLParameters parameters = socket.getSSLParameters();
        parameters.setEndpointIdentificationAlgorithm(null);
        socket.setSSLParameters(parameters);
      }
      socket.connect(new InetSocketAddress(config.host, config.port), CONNECT_TIMEOUT_MS);
      socket.startHandshake();
      socket.setSoTimeout(HANDSHAKE_TIMEOUT_MS);
      return socket;
    }

    private void handshake() throws IOException {
      byte[] key = new byte[16];
      RANDOM.nextBytes(key);
      String encoded = Base64.encodeToString(key, Base64.NO_WRAP);
      String request =
          "GET /connect HTTP/1.1\r\n"
              + "Host: "
              + config.host
              + ":"
              + config.port
              + "\r\n"
              + "Upgrade: websocket\r\n"
              + "Connection: Upgrade\r\n"
              + "Sec-WebSocket-Key: "
              + encoded
              + "\r\n"
              + "Sec-WebSocket-Version: 13\r\n"
              + "Authorization: Bearer "
              + config.token
              + "\r\n"
              + "x-airreload-vm-path: "
              + vm.path
              + "\r\n"
              + "\r\n";
      output.write(request.getBytes(UTF8));
      output.flush();
      String headers = readHttpHeaders();
      if (!headers.startsWith("HTTP/1.1 101") && !headers.startsWith("HTTP/1.0 101")) {
        throw new IOException("Airreload tunnel upgrade rejected");
      }
      link.setSoTimeout(0);
    }

    private String readHttpHeaders() throws IOException {
      ByteArrayOutputStream buffer = new ByteArrayOutputStream();
      int matched = 0;
      while (matched < 4) {
        int next = input.read();
        if (next < 0) {
          throw new IOException("Closed during WebSocket handshake");
        }
        if (buffer.size() > 8192) {
          throw new IOException("WebSocket handshake too large");
        }
        buffer.write(next);
        if ((matched == 0 || matched == 2) && next == '\r') {
          matched++;
        } else if ((matched == 1 || matched == 3) && next == '\n') {
          matched++;
        } else if (next == '\r') {
          matched = 1;
        } else {
          matched = 0;
        }
      }
      return new String(buffer.toByteArray(), UTF8);
    }

    private void pingLoop() {
      while (!closed) {
        try {
          Thread.sleep(PING_INTERVAL_MS);
          sendFrame((byte) 0x9, new byte[0]);
        } catch (Exception ignored) {
          close();
          return;
        }
      }
    }

    private void readLoop() throws Exception {
      while (!closed) {
        Frame frame = readFrame();
        if (frame == null) {
          return;
        }
        switch (frame.opcode) {
          case 0x1:
            handleText(new String(frame.payload, UTF8));
            break;
          case 0x8:
            return;
          case 0x9:
            sendFrame((byte) 0xA, frame.payload);
            break;
          case 0xA:
            break;
          default:
            throw new IOException("Unsupported WebSocket opcode");
        }
      }
    }

    private void handleText(String raw) throws Exception {
      if (raw.length() > MAX_FRAME_CHARS) {
        throw new IOException("Invalid frame");
      }
      JSONObject message = new JSONObject(raw);
      int id = message.getInt("id");
      String op = message.getString("op");
      if ("open".equals(op)) {
        handleOpen(id);
      } else if ("data".equals(op)) {
        Socket socket = sockets.get(id);
        if (socket != null) {
          byte[] bytes = Base64.decode(message.getString("data"), Base64.DEFAULT);
          socket.getOutputStream().write(bytes);
          socket.getOutputStream().flush();
        }
      } else if ("close".equals(op)) {
        drop(id);
      } else if (!"ready".equals(op)) {
        throw new IOException("Unknown tunnel operation");
      }
    }

    private void handleOpen(final int id) throws Exception {
      synchronized (sockets) {
        if (sockets.size() + reserved.size() >= MAX_SOCKETS
            || sockets.containsKey(id)
            || reserved.contains(id)) {
          throw new IOException("Invalid channel request");
        }
        reserved.add(id);
      }
      try {
        io.execute(
            new Runnable() {
              @Override
              public void run() {
                Socket socket = new Socket();
                try {
                  socket.connect(
                      new InetSocketAddress(vm.address, vm.port), VM_CONNECT_TIMEOUT_MS);
                  socket.setTcpNoDelay(true);
                  synchronized (sockets) {
                    reserved.remove(id);
                    if (closed) {
                      socket.close();
                      return;
                    }
                    sockets.put(id, socket);
                  }
                  sendJson("{\"op\":\"ready\",\"id\":" + id + "}");
                  readSocket(id, socket);
                } catch (Exception ignored) {
                  synchronized (sockets) {
                    reserved.remove(id);
                  }
                  closeQuietly(socket);
                  sendClose(id);
                }
              }
            });
      } catch (Exception error) {
        synchronized (sockets) {
          reserved.remove(id);
        }
        sendClose(id);
      }
    }

    private void readSocket(int id, Socket socket) {
      InputStream stream;
      try {
        stream = socket.getInputStream();
      } catch (IOException error) {
        sendClose(id);
        drop(id);
        return;
      }
      byte[] buffer = new byte[CHUNK_SIZE];
      try {
        int read;
        while ((read = stream.read(buffer)) >= 0) {
          byte[] chunk = Arrays.copyOf(buffer, read);
          JSONObject message = new JSONObject();
          message.put("op", "data");
          message.put("id", id);
          message.put("data", Base64.encodeToString(chunk, Base64.NO_WRAP));
          sendJson(message.toString());
        }
      } catch (Exception ignored) {
      } finally {
        sendClose(id);
        drop(id);
      }
    }

    private void sendClose(int id) {
      sendJson("{\"op\":\"close\",\"id\":" + id + "}");
    }

    private void sendJson(String json) {
      try {
        sendFrame((byte) 0x1, json.getBytes(UTF8));
      } catch (Exception ignored) {
        close();
      }
    }

    private void sendFrame(byte opcode, byte[] payload) throws IOException {
      if (closed) {
        return;
      }
      byte[] mask = new byte[4];
      RANDOM.nextBytes(mask);
      ByteArrayOutputStream frame = new ByteArrayOutputStream(payload.length + 14);
      frame.write(0x80 | opcode);
      if (payload.length <= 125) {
        frame.write(0x80 | payload.length);
      } else if (payload.length <= 0xFFFF) {
        frame.write(0x80 | 126);
        frame.write((payload.length >>> 8) & 0xFF);
        frame.write(payload.length & 0xFF);
      } else {
        frame.write(0x80 | 127);
        for (int shift = 56; shift >= 0; shift -= 8) {
          frame.write((int) ((payload.length & 0xFFFFFFFFL) >>> shift) & 0xFF);
        }
      }
      frame.write(mask);
      for (int i = 0; i < payload.length; i++) {
        frame.write(payload[i] ^ mask[i & 3]);
      }
      synchronized (writeLock) {
        if (closed) {
          return;
        }
        output.write(frame.toByteArray());
        output.flush();
      }
    }

    private Frame readFrame() throws IOException {
      int first = input.read();
      if (first < 0) {
        return null;
      }
      int second = input.readUnsignedByte();
      int opcode = first & 0x0F;
      boolean masked = (second & 0x80) != 0;
      long length = second & 0x7F;
      if (length == 126) {
        length = input.readUnsignedShort();
      } else if (length == 127) {
        length = input.readLong();
      }
      if (length < 0 || length > MAX_FRAME_CHARS) {
        throw new IOException("Invalid frame");
      }
      byte[] mask = new byte[4];
      if (masked) {
        input.readFully(mask);
      }
      byte[] payload = new byte[(int) length];
      input.readFully(payload);
      if (masked) {
        for (int i = 0; i < payload.length; i++) {
          payload[i] = (byte) (payload[i] ^ mask[i & 3]);
        }
      }
      return new Frame(opcode, payload);
    }

    private void drop(int id) {
      Socket socket;
      synchronized (sockets) {
        socket = sockets.remove(id);
      }
      closeQuietly(socket);
    }

    private void close() {
      if (closed) {
        return;
      }
      closed = true;
      synchronized (sockets) {
        Iterator<Socket> iterator = sockets.values().iterator();
        while (iterator.hasNext()) {
          closeQuietly(iterator.next());
        }
        sockets.clear();
      }
      io.shutdownNow();
      try {
        if (link != null) {
          link.close();
        }
      } catch (IOException ignored) {
      }
    }

    private static void closeQuietly(Socket socket) {
      if (socket == null) {
        return;
      }
      try {
        socket.close();
      } catch (IOException ignored) {
      }
    }
  }

  private static final class Frame {
    final int opcode;
    final byte[] payload;

    Frame(int opcode, byte[] payload) {
      this.opcode = opcode;
      this.payload = payload;
    }
  }
}
