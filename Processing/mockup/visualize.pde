// visualize: receive the demoSpace merged texture via Spout and show it on the
// physical room (wall / floor / wall) in 3D, using PeasyCam to orbit.
//
// The received texture is one image; each surface quad samples only its own
// texture rows (792..2087 = floor band etc.), matching the demoSpace layout.
//
// LazyGui controls:
//   Show TUIO - bake simulated walker cursors onto the floor over the Spout image
//   Receiver   - Spout/Syphon (native GPU share) or NDI; all three attach to
//                the first sender found
//   3D        - orbit 3D room vs flat 2D texture in the viewport
//   Mode      - simulated walkers vs. a TUIO cursor on the floor
//               (left-drag in 2D, Ctrl + left-drag with camera locked in 3D)

import spout.*;
import com.krab.lazy.*;
import peasy.*;
import ndi.stream.*;
import java.util.Arrays;

// room geometry in meters (matches pharus observation space + wall px pitch)
final float ROOM_W = SPACE_W;                          // 21.842 floor/wall width
final float ROOM_D = SPACE_H;                          // 5.938 floor depth
final float WALL_H = 1929.0 * SPACE_W / 9974.0;        // 4.224 wall height

// texture row boundaries of the merged 4096x2880 texture
final float TEX_ROWS = 2880.0;
final float V_FLOOR_TOP = 792.0 / TEX_ROWS;
final float V_FLOOR_BOT = 2087.0 / TEX_ROWS;
final float V_WALL_B_TOP = 2879.0 / TEX_ROWS;

Spout spoutRecv;
long spoutLastRetry = 0;
PImage spoutImg;
PImage uvFallback; // data/uv_texture.png: shown on the room quads until a sender appears
int fpsFrames = 0;
long fpsLastMillis = 0;
double fpsShown = 0;
PeasyCam cam;
LazyGui gui;

boolean showTUIO, use3D, modeMouse;

// mouse-driven cursor state
boolean dragging = false;
boolean modfierDown = false;
Walker dragWalker;
java.util.HashMap<Long, Integer> walkerColors = new java.util.HashMap<Long, Integer>();

void setupViz() {
  uvFallback = flipY(loadImage("uv_texture.png")); // chart authored V-up; sampling expects demoSpace row layout
  // per-frame-updated textures keep a stale mip chain in P3D; without this,
  // downsampled textured quads sample empty mips and render nearly invisible
  hint(DISABLE_TEXTURE_MIPMAPS);
  cam = new PeasyCam(this, 22);
  // PeasyCam's built-in reset returns to an invalid identity view for the room.
  cam.setResetOnDoubleClick(false);
  cam.rotateY(-PI / 6.0); // default: slight yaw
  cam.rotateX(PI / 5.0);  // ...and slightly from above
  gui = new LazyGui(this);
  if (OS.equals("windows")) {
    try {
      // connect in receiveNative retries: binds to the first sender sharing
      spoutRecv = new Spout(this);
    }
    catch (Throwable e) {
      println("Spout init failed: " + e);
      spoutRecv = null;
    }
  }
  // macOS Syphon: no eager client here - receiveNative runs background
  // discovery and subscribes to the first server found
}

// Syphon (macOS) via reflection so the sketch still compiles on Windows,
// where the Syphon library is not installed.
// Discovery of available servers runs on a worker thread (the library's
// listServers() blocks ~0.5s) and picks the FIRST server; the client then
// subscribes to that name.
Object syphonClient;
java.lang.reflect.Method syphonGetImage;
String syphonSubscribed;
volatile String syphonDiscovered;
volatile boolean syphonScanRunning;
long syphonLastScan = 0;

void startSyphonScan() {
  syphonScanRunning = true;
  new Thread(() -> {
    String found = null;
    try {
      Class<?> c = Class.forName("codeanticode.syphon.SyphonClient");
      java.util.HashMap<String, String>[] servers =
        (java.util.HashMap<String, String>[]) c.getMethod("listServers").invoke(null);
      for (java.util.HashMap<String, String> s : servers) {
        String name = s.get("ServerName");
        if (name != null) {
          found = name;
          break;
        }
      }
    }
    catch (Throwable t) {
      // keep previous discovery result
    }
    if (found != null) syphonDiscovered = found;
    syphonScanRunning = false;
  }
  , "syphon-scan").start();
}

void setupSyphonReceiver(String serverName) {
  try {
    Class<?> c = Class.forName("codeanticode.syphon.SyphonClient");
    // 3-arg form with null appName = subscribe by SERVER NAME only.
    // NOTE: the 2-arg constructor sets the APP name, not the server name!
    syphonClient = c.getConstructor(PApplet.class, String.class, String.class)
      .newInstance(this, null, serverName);
    syphonGetImage = c.getMethod("getImage", PImage.class);
    syphonActiveM = c.getMethod("active");
    syphonNewFrameM = c.getMethod("newFrame");
    syphonSubscribed = serverName;
    println("Syphon client for: " + serverName);
  }
  catch (Throwable e) {
    Throwable c = e.getCause() != null ? e.getCause() : e;
    c.printStackTrace();
    println("Syphon init failed: " + c);
    syphonGetImage = null;
  }
}


// --- GUI state (read once per frame, before simulation update) ---

void readGui() {
  showTUIO = gui.toggle("Show TUIO", true);
  String nativeLabel = OS.equals("macos") ? "Syphon" : "Spout";
  recvMode = gui.radio("Receiver", Arrays.asList(nativeLabel, "NDI"), nativeLabel);
  use3D = gui.toggle("3D", true);
  gui.pushFolder("Mode");
  modeMouse = gui.toggle("Mouse cursor", false);
  gui.text("Mouse cursor help", "");
  gui.textSet("Mouse cursor help", "2D: Left mouse drag\n3D: Alt + Left mouse drag\nCamera locks while held");
  gui.popFolder();
}

// --- texture receive (native GPU share or NDI) ---

String recvMode = "Spout";

boolean useNDI() {
  return recvMode.equals("NDI");
}

void receiveTexture() {
  if (useNDI()) receiveNDI();
  else receiveNative();
}

// --- NDI ---

NDIReceiver ndiReceiver;
NDIVideoFrame ndiFrame;
long ndiLastTry = 0;
// discovery+connect run on a worker thread: NDIFinder startup and
// waitForSources() can block for seconds and must never touch the draw thread.
// The finder is created once and kept alive; its native mDNS browser keeps
// discovering between retries.
NDIFinder ndiFinder;
volatile boolean ndiConnecting = false;

void startNdiConnect() {
  ndiConnecting = true;
  new Thread(() -> {
    try {
      if (ndiFinder == null) ndiFinder = new NDIFinder();
      NDISource[] srcs = ndiFinder.getCurrentSources();
      if (srcs.length == 0) {
        ndiFinder.waitForSources(1500);
        srcs = ndiFinder.getCurrentSources();
      }
      if (srcs.length > 0 && ndiReceiver != null && ndiReceiver.getConnectionCount() < 1) {
        ndiReceiver.connect(srcs[0]);
        println("NDI connected: " + srcs[0].getSourceName());
      }
    }
    catch (Exception e) {
      if (millis() - ndiLastRetryPrint > 2000) {
        ndiLastRetryPrint = millis();
        println("NDI connect failed: " + e);
      }
    }
    finally {
      ndiConnecting = false;
    }
  }
  , "ndi-connect").start();
}

void receiveNDI() {
  try {
    if (ndiReceiver == null) {
      // BGRX_BGRA bytes == PImage ARGB ints in little-endian: bulk int copy
      ndiReceiver = new NDIReceiver(NDIReceiver.ColorFormat.BGRX_BGRA, 100, false, "mockup");
      ndiFrame = new NDIVideoFrame();
    }
    if (ndiReceiver.getConnectionCount() < 1 && !ndiConnecting
      && millis() - ndiLastTry > 2000) {
      ndiLastTry = millis();
      startNdiConnect();
    }
    NDIFrameType ft = ndiReceiver.receiveCapture(ndiFrame, null, null, 0);
    if (ft == NDIFrameType.VIDEO) {
      int w = ndiFrame.getXResolution();
      int h = ndiFrame.getYResolution();
      if (spoutImg == null || spoutImg.width != w || spoutImg.height != h) {
        spoutImg = createImage(w, h, ARGB);
      }
      // BGRA bytes in little-endian == PImage ARGB ints: one bulk copy, no per-pixel work
      NDIUtilities.copyBufferToPixels(ndiFrame.getData(), spoutImg.pixels);
      spoutImg.updatePixels();
    }
  }
  catch (Exception e) {
    if (millis() - ndiLastRetryPrint > 2000) {
      ndiLastRetryPrint = millis();
      println("NDI receive failed: " + e);
    }
  }
}
long ndiLastRetryPrint = 0;

void stop() {
  if (ndiFrame != null) ndiFrame.close();
  if (ndiReceiver != null) ndiReceiver.close();
  if (ndiFinder != null) ndiFinder.close();
}

boolean syphonWasActive = false;
long syphonLastRetry = 0;
java.lang.reflect.Method syphonActiveM, syphonNewFrameM;

void receiveNative() {
  if (OS.equals("macos")) {
    // background discovery: first server found wins
    if (!syphonScanRunning && millis() - syphonLastScan > 2000) {
      syphonLastScan = millis();
      startSyphonScan();
    }
    String want = syphonDiscovered;
    if (want == null) return;
    if (syphonGetImage == null || !want.equals(syphonSubscribed)) {
      if (syphonClient != null) {
        try {
          syphonClient.getClass().getMethod("stop").invoke(syphonClient);
        }
        catch (Exception e) {
        }
      }
      setupSyphonReceiver(want);
      return;
    }
    try {
      boolean active = (Boolean) syphonActiveM.invoke(syphonClient);
      if (active && !syphonWasActive) println("Syphon client active");
      syphonWasActive = active;
      if (!active && millis() - syphonLastRetry > 2000) {
        // server gone/restarted: rebuild the client for the same name
        syphonLastRetry = millis();
        try {
          syphonClient.getClass().getMethod("stop").invoke(syphonClient);
        }
        catch (Exception e) {
        }
        setupSyphonReceiver(want);
      }
      if (!active) return;
      // getImage(dest) needs a destination buffer of matching size
      if (spoutImg == null) spoutImg = createImage(4096, 2880, ARGB); // = demoSpace MAX_SIDE layout
      // only pull when a new frame arrived: skips the library's full-size
      // offscreen render+blit otherwise
      boolean fresh = (Boolean) syphonNewFrameM.invoke(syphonClient);
      if (!fresh) return;
      PImage res = (PImage) syphonGetImage.invoke(syphonClient, spoutImg);
      if (res != null) spoutImg = res;
    }
    catch (Exception e) {
      Throwable c = e.getCause() != null ? e.getCause() : e;
      if (millis() - syphonLastRetry > 2000) {
        syphonLastRetry = millis();
        println("Syphon receive failed: " + c);
      }
    }
    return;
  }
  // Windows/Spout: exact name first, then any first sender; retry every 2 s
  if (spoutRecv == null) return;
  if (!spoutRecv.isConnected()) {
    if (millis() - spoutLastRetry > 2000) {
      spoutLastRetry = millis();
      // JSPOUT treats an empty name as "first sender that is sharing";
      // setSenderName("") first because createReceiver("") substitutes it
      spoutRecv.setSenderName("");
      if (spoutRecv.createReceiver("")) println("Spout connected to: " + spoutRecv.getSenderName());
    }
    return;
  }
  int sw = spoutRecv.getSenderWidth();
  int sh = spoutRecv.getSenderHeight();
  if (sw <= 0 || sh <= 0) return;
  if (spoutImg == null || spoutImg.width != sw || spoutImg.height != sh) {
    spoutImg = createImage(sw, sh, ARGB);
  }
  spoutRecv.receiveTexture(spoutImg);
}

// walkers drawn natively per viewport (no per-frame bake into the big texture)
void drawWalkers2D(float W, float H) {
  strokeWeight(5);
  noFill();
  for (Walker w : walkers) {
    color c = walkerColor(w.id);
    stroke(c);
    float cx = w.nx() * W;
    float cy = w.ny() * H;
    float d = H * 0.05;
    ellipse(cx, cy, d, d);
    noStroke();
    fill(c);
    textSize(H * 0.03);
    textAlign(CENTER, CENTER);
    text(str(w.id), cx, cy);
    stroke(c);
  }
}

// circles laid on the floor quad (world meters, floor spans y=0)
void drawWalkers3D() {
  float hd = ROOM_D / 2.0;
  noStroke();
  for (Walker w : walkers) {
    color c = walkerColor(w.id);
    float wx = w.x - ROOM_W / 2.0;
    float wz = w.y / SPACE_H * ROOM_D - hd;
    pushMatrix();
    translate(wx, -0.02, wz);
    rotateX(-HALF_PI);
    fill(c);
    ellipse(0, 0, 0.35, 0.35);
    popMatrix();
  }
}

color walkerColor(int id) {
  Long key = (long) id;
  Integer stored = walkerColors.get(key);
  if (stored != null) return stored;
  color c = color(random(80, 255), random(80, 255), random(80, 255));
  walkerColors.put(key, (int) c);
  return c;
}

// vertical mirror: row y of src -> row (h-1-y) of dst
PImage flipY(PImage src) {
  src.loadPixels();
  PImage dst = createImage(src.width, src.height, src.format);
  dst.loadPixels();
  for (int y = 0; y < src.height; y++) {
    arraycopy(src.pixels, (src.height - 1 - y) * src.width, dst.pixels, y * src.width, src.width);
  }
  dst.updatePixels();
  return dst;
}

// --- viewport ---

void drawViz() {
  receiveTexture();
  PImage face = spoutImg;

  if (use3D) draw3DRoom(face);
  else draw2DFlat(face);

  // LazyGui: text(name, value) sets the value only at widget creation;
  // ongoing updates must go through textSet
  gui.pushFolder("logs");
  gui.text("TUIO logs", "");
  gui.textSet("TUIO logs", join(tuioLogs.toArray(new String[0]), "\n"));
  gui.popFolder();

  fpsFrames++;
  if (millis() - fpsLastMillis >= 1000) {
    fpsShown = fpsFrames * 1000.0 / (millis() - fpsLastMillis);
    fpsLastMillis = millis();
    fpsFrames = 0;
  }
}

void draw3DRoom(PImage face) {
  background(25);
  noLights();
  // room is meter-scale (~22 m) but the P3D default frustum is pixel-scale
  // (near ~62 at 720 px) -> everything sits inside the near plane and clips.
  perspective(PI / 3.0, width / (float) height, 0.1f, 1000);

  noStroke();
  fill(255);
  textureMode(NORMAL);
  textureWrap(CLAMP);

  float hw = ROOM_W / 2.0;
  float hd = ROOM_D / 2.0;

  // one texture (the full merged face), sampled per surface via uv row bands;
  // uv fallback keeps the quads readable (and the uv layout visible) pre-connect
  PImage tex = face != null ? face : uvFallback;
  beginShape(QUADS);
  if (tex != null) texture(tex);
  // left/top wall region (rows 0..792): junction row 792 at floor edge z=+hd,
  // row 0 at the wall top
  vertex(-hw, 0, hd, 0, V_FLOOR_TOP);
  vertex( hw, 0, hd, 1, V_FLOOR_TOP);
  vertex( hw, -WALL_H, hd, 1, 0);
  vertex(-hw, -WALL_H, hd, 0, 0);

  // floor: row 792 at z=+hd, row 2087 at z=-hd
  vertex(-hw, 0, hd, 0, V_FLOOR_TOP);
  vertex( hw, 0, hd, 1, V_FLOOR_TOP);
  vertex( hw, 0, -hd, 1, V_FLOOR_BOT);
  vertex(-hw, 0, -hd, 0, V_FLOOR_BOT);

  // right/bottom wall region (rows 2087..2879): junction row 2087 at z=-hd
  vertex(-hw, 0, -hd, 0, V_FLOOR_BOT);
  vertex( hw, 0, -hd, 1, V_FLOOR_BOT);
  vertex( hw, -WALL_H, -hd, 1, V_WALL_B_TOP);
  vertex(-hw, -WALL_H, -hd, 0, V_WALL_B_TOP);
  endShape();

  if (showTUIO) drawWalkers3D();

  // room outline for orientation
  if (tex != null) noTexture();
  noFill();
  stroke(120);
  strokeWeight(1);
  line(-hw, 0, hd, -hw, -WALL_H, hd);
  line( hw, 0, hd, hw, -WALL_H, hd);
  line(-hw, -WALL_H, hd, hw, -WALL_H, hd);
  line(-hw, 0, -hd, -hw, -WALL_H, -hd);
  line( hw, 0, -hd, hw, -WALL_H, -hd);
  line(-hw, -WALL_H, -hd, hw, -WALL_H, -hd);
}

void draw2DFlat(PImage face) {
  // draw under the HUD's default camera: endHUD restores PeasyCam's matrix,
  // so toggling back to 3D resumes seamlessly and PeasyCam is untouched in 2D
  cam.beginHUD();
  background(25);
  noLights();
  if (face != null) image(face, 0, 0, width, height);
  else {
    fill(200);
    textAlign(CENTER, CENTER);
    text("Waiting for sender", width / 2, height / 2);
  }
  if (showTUIO) drawWalkers2D(width, height);
  cam.endHUD();
}

// --- mouse mode: drag a TUIO cursor on the floor ---

void keyPressed() {
    if ( key == CODED && keyCode == ALT && modeMouse) {
      modfierDown = true;
      cam.setActive(false);
      println("alt down");
  }
}

void keyReleased() {
  if (key == CODED && keyCode == ALT ) {
    modfierDown = false;
    cam.setActive(true);
    println("alt up");
  }
}

void mousePressed() {
  if (modeMouse && gui.isMouseOutsideGui() && modfierDown) {
    println("walker sim");
    //if (use3D) cam.setActive(false);

    PVector hit = rayToFloor(mouseX, mouseY);
    if (hit == null) return;
    PVector pos = new PVector(hit.x, hit.y);
    dragWalker = new Walker(nextWalkerId++, pos, pos, pos);
    dragWalker.frozen = true;
    walkers.add(dragWalker);
    dragging = true;
    tuioLog("mouse cursor id " + dragWalker.id + " at (" + nf(hit.x, 2, 2) + ", " + nf(hit.y, 2, 2) + ")");
  }
}

void mouseDragged() {
  if (!dragging || dragWalker == null) return;
  PVector hit = rayToFloor(mouseX, mouseY);
  if (hit == null) return;
  float dt = 1.0 / max(1, frameRate);
  dragWalker.vx = (hit.x - dragWalker.x) / dt;
  dragWalker.vy = (hit.y - dragWalker.y) / dt;
  dragWalker.x = hit.x;
  dragWalker.y = hit.y;
}

void mouseReleased() {
  if (!dragging) return;
  dragging = false;
  if (dragWalker != null) {
    walkers.remove(dragWalker);   // vanishes via the per-frame alive diff
    tuioLog("mouse cursor left id " + dragWalker.id);
    dragWalker = null;
  }
}

// Screen point -> floor in observation coords (x, y in meters).
// 3D inverts the floor quad projected by Processing; 2D inverts its floor band.
PVector rayToFloor(float mx, float my) {
  if (!use3D) {
    float floorTop = FLOOR_TUIO_Y0 * height;
    float floorBottom = FLOOR_TUIO_Y1 * height;
    if (mx < 0 || mx > width || my < floorTop || my > floorBottom) return null;
    return new PVector(
      map(mx, 0, width, 0, SPACE_W),
      map(my, floorTop, floorBottom, SPACE_H, 0)
      );
  }

  float hw = ROOM_W / 2.0;
  float hd = ROOM_D / 2.0;
  // Project floor corners in the same camera view used to draw the room.
  // Corner order: (u,v) = (0,0), (1,0), (1,1), (0,1).
  float x0 = screenX(-hw, 0, hd), y0 = screenY(-hw, 0, hd);
  float x1 = screenX( hw, 0, hd), y1 = screenY( hw, 0, hd);
  float x2 = screenX( hw, 0, -hd), y2 = screenY( hw, 0, -hd);
  float x3 = screenX(-hw, 0, -hd), y3 = screenY(-hw, 0, -hd);

  // Unit-square UV -> projected screen homography, then invert for the mouse.
  float dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3;
  float dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3;
  float denominator = dx1 * dy2 - dx2 * dy1;
  if (abs(denominator) < 1e-6) return null;
  float g = (dx3 * dy2 - dx2 * dy3) / denominator;
  float h = (dx1 * dy3 - dx3 * dy1) / denominator;
  PMatrix3D uvToScreen = new PMatrix3D(
    x1 - x0 + g * x1, x3 - x0 + h * x3, 0, x0,
    y1 - y0 + g * y1, y3 - y0 + h * y3, 0, y0,
    0, 0, 1, 0,
    g, h, 0, 1
    );
  if (!uvToScreen.invert()) return null;
  float w = uvToScreen.multW(mx, my, 0);
  if (w < 1e-6) return null;
  float u = uvToScreen.multX(mx, my, 0) / w;
  float v = uvToScreen.multY(mx, my, 0) / w;
  if (u < 0 || u > 1 || v < 0 || v > 1) return null;
  return new PVector(u * SPACE_W, (1 - v) * SPACE_H);
}
