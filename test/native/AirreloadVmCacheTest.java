package dev.airreload.runtime;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

/** Runs the real cache cleanup without needing an emulator or Android process. */
public final class AirreloadVmCacheTest {
  public static void main(String[] args) throws Exception {
    Path root = new File(args[0]).toPath();
    File[] dirs = new File[5];
    for (int i = 0; i < 4; i++) {
      Path dir = Files.createDirectory(root.resolve("cache-" + i));
      dirs[i] = dir.toFile();
      Files.write(dir.resolve("airreload-vm.json"),
          "{\"port\":12345,\"path\":\"/old-process=/\"}".getBytes(StandardCharsets.UTF_8));
      Files.write(dir.resolve("app-data.txt"), "keep".getBytes(StandardCharsets.UTF_8));
    }
    AirreloadNativeTunnel.clearVmCache(dirs);
    // Also accepts a missing directory and handles an already-cleared cache.
    dirs[4] = root.resolve("missing").toFile();
    AirreloadNativeTunnel.clearVmCache(dirs);
    for (int i = 0; i < 4; i++) {
      Path dir = dirs[i].toPath();
      if (Files.exists(dir.resolve("airreload-vm.json"))) {
        throw new AssertionError("Old VM endpoint survived startup");
      }
      String data = new String(Files.readAllBytes(dir.resolve("app-data.txt")), StandardCharsets.UTF_8);
      if (!"keep".equals(data)) throw new AssertionError("Unrelated cache data changed");
    }
    System.out.println("Native VM cache regression passed");
  }
}
