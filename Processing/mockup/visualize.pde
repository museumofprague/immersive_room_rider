// visualize: receive the demoSpace merged texture via Spout and show it on the
// physical room (wall / floor / wall) in 3D, using PeasyCam to orbit.
//
// The received texture is one image; each surface quad samples only its own
// texture rows (792..2087 = floor band etc.), matching the demoSpace layout.
//
// LazyGui controls:
//   Show TUIO - bake simulated walker cursors onto the floor over the Spout image
//   Receiver   - Spout/Syphon (native GPU share) or NDI
//   3D        - orbit 3D room vs flat 2D texture in the viewport
//   Mode      - simulated walkers vs. mouse-dragging a TUIO cursor on the floor

import spout.*;
import com.krab.lazy.*;
import peasy.*;
import peasy.CameraState;
import ndi.stream.*;
import java.util.Arrays;

final String SENDER_NAME = "processing_demospace";

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
PImage spoutImg;
int fpsFrames = 0;
long fpsLastMillis = 0;
double fpsShown = 0;
PeasyCam cam;
CameraState camDefaultView;
LazyGui gui;

boolean showTUIO, use3D, modeMouse;
final String MODE_SIM = "Simulated walkers";
final String MODE_MOUSE = "Mouse cursor";

// mouse-driven cursor state
boolean dragging = false;
Walker dragWalker;
java.util.HashMap<Long, Integer> walkerColors = new java.util.HashMap<Long, Integer>();

void setupViz() {
  // per-frame-updated textures keep a stale mip chain in P3D; without this,
  // downsampled textured quads sample empty mips and render nearly invisible
  hint(DISABLE_TEXTURE_MIPMAPS);
  cam = new PeasyCam(this, 22);
  // PeasyCam's built-in double-click reset() always returns to its identity
  // (side-on) state; instead disable it and restore our snapshotted default
  // view via the library's own setState() on double-click (see mousePressed)
  cam.setResetOnDoubleClick(false);
  cam.rotateY(-PI / 6.0); // default: slight yaw
  cam.rotateX(PI / 5.0);  // ...and slightly from above
  camDefaultView = cam.getState();
  gui = new LazyGui(this);
  if (OS.equals("windows")) {
    try {
      spoutRecv = new Spout(this);
      if (!spoutRecv.createReceiver(SENDER_NAME)) {
        println("Spout: sender '" + SENDER_NAME + "' not found yet");
      }
    } catch (Throwable e) {
      println("Spout init failed: " + e);
      spoutRecv = null;
    }
  } else if (OS.equals("macos")) {
    setupSyphonReceiver();
  }
}

// Syphon (macOS) via reflection so the sketch still compiles on Windows,
// where the Syphon library is not installed
Object syphonClient;
java.lang.reflect.Method syphonGetImage;

void setupSyphonReceiver() {
  try {
    Class<?> c = Class.forName("codeanticode.syphon.SyphonClient");
    // 3-arg form with null appName = subscribe by SERVER NAME only.
    // NOTE: the 2-arg constructor sets the APP name, not the server name!
    syphonClient = c.getConstructor(PApplet.class, String.class, String.class)
                    .newInstance(this, null, SENDER_NAME);
    syphonGetImage = c.getMethod("getImage", PImage.class);
    syphonActiveM = c.getMethod("active");
    syphonNewFrameM = c.getMethod("newFrame");
    // NB: no listServers() here - it sleeps up to 500ms on the main thread;
    // discovery happens via the client re-created in the receiveNative retry
  } catch (Throwable e) {
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
  modeMouse = gui.radio("Mode", Arrays.asList(MODE_SIM, MODE_MOUSE), MODE_SIM).equals(MODE_MOUSE);
}

// --- texture receive (native GPU share or NDI) ---

String recvMode = "Spout";

boolean useNDI() { return recvMode.equals("NDI"); }

void receiveTexture() {
  if (useNDI()) receiveNDI();
  else receiveNative();
}

// --- NDI ---

NDIReceiver ndiReceiver;
NDIVideoFrame ndiFrame;
long ndiLastTry = 0;

void receiveNDI() {
  try {
    if (ndiReceiver == null) {
      // BGRX_BGRA bytes == PImage ARGB ints in little-endian: bulk int copy
      ndiReceiver = new NDIReceiver(NDIReceiver.ColorFormat.BGRX_BGRA, 100, false, "mockup");
      ndiFrame = new NDIVideoFrame();
    }
    if (ndiReceiver.getConnectionCount() < 1 && millis() - ndiLastTry > 2000) {
      ndiLastTry = millis();
      try (NDIFinder finder = new NDIFinder()) {
        NDISource[] srcs = finder.getCurrentSources();
        if (srcs.length == 0) {
          finder.waitForSources(1500);
          srcs = finder.getCurrentSources();
        }
        if (srcs.length > 0) {
          NDISource pick = srcs[0];
          for (NDISource s : srcs) {
            if (s.getSourceName().contains(SENDER_NAME)) { pick = s; break; }
          }
          ndiReceiver.connect(pick);
          println("NDI connected: " + pick.getSourceName());
        }
      }
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
  } catch (Exception e) {
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
}

boolean syphonWasActive = false;
long syphonLastRetry = 0;
java.lang.reflect.Method syphonActiveM, syphonNewFrameM;

void receiveNative() {
  if (OS.equals("macos")) {
    if (syphonGetImage == null) return;
    try {
      // the client only looks up the server at construction; re-create it until
      // the demoSpace server appears (mockup may start first)
      boolean active = (Boolean) syphonActiveM.invoke(syphonClient);
      if (active && !syphonWasActive) println("Syphon client active");
      syphonWasActive = active;
      if (!active && millis() - syphonLastRetry > 2000) {
        syphonLastRetry = millis();
        try { syphonClient.getClass().getMethod("stop").invoke(syphonClient); } catch (Exception e) {}
        setupSyphonReceiver();
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
    } catch (Exception e) {
      Throwable c = e.getCause() != null ? e.getCause() : e;
      if (millis() - syphonLastRetry > 2000) {
        syphonLastRetry = millis();
        println("Syphon receive failed: " + c);
      }
    }
    return;
  }
  if (spoutRecv == null || !spoutRecv.isConnected()) return;
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

  // LazyGui + PeasyCam integration pattern: draw GUI screen-space via HUD,
  // and let the GUI eat mouse input before the camera
  cam.beginHUD();
  gui.draw();
  fill(255);
  noStroke();
  textAlign(RIGHT, TOP);
  textSize(14);
  text(nf((float) fpsShown, 2, 0) + " fps", width - 10, 8);
  cam.endHUD();
  cam.setMouseControlled(use3D && gui.isMouseOutsideGui());
}

void draw3DRoom(PImage face) {
  // when the GUI holds the mouse, PeasyCam is inactive and stops applying its
  // camera -> re-apply the frozen camera manually, else the scene falls back
  // to the pixel-scale default and vanishes
  if (!cam.isActive()) {
    float[] e = cam.getPosition();
    float[] l = cam.getLookAt();
    camera(e[0], e[1], e[2], l[0], l[1], l[2], 0, 1, 0);
  }
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

  // one texture (the full merged face), sampled per surface via uv row bands
  beginShape(QUADS);
  if (face != null) texture(face);
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

  if (showTUIO && face != null) drawWalkers3D();

  // room outline for orientation
  if (face != null) noTexture();
  noFill();
  stroke(120);
  strokeWeight(1);
  line(-hw, 0, hd, -hw, -WALL_H, hd);
  line( hw, 0, hd,  hw, -WALL_H, hd);
  line(-hw, -WALL_H, hd,  hw, -WALL_H, hd);
  line(-hw, 0, -hd, -hw, -WALL_H, -hd);
  line( hw, 0, -hd,  hw, -WALL_H, -hd);
  line(-hw, -WALL_H, -hd,  hw, -WALL_H, -hd);
}

void draw2DFlat(PImage face) {
  cam.setActive(false); // stop PeasyCam consuming the mouse in 2D mode
  camera(); // reset to default camera after PeasyCam's pre-draw update
  background(25);
  noLights();
  if (face != null) image(face, 0, 0, width, height);
  else {
    fill(200);
    textAlign(CENTER, CENTER);
    text("Waiting for sender", width / 2, height / 2);
  }
  if (showTUIO) drawWalkers2D(width, height);
}

// --- mouse mode: drag a TUIO cursor on the floor ---

void mousePressed() {
  if (mouseEvent.getCount() == 2 && use3D && gui.isMouseOutsideGui()) {
    cam.setState(camDefaultView, 300); // smooth back to default view
    return;
  }
  if (!modeMouse || !gui.isMouseOutsideGui() || mouseButton != LEFT) return;
  PVector hit = rayToFloor(mouseX, mouseY);
  if (hit == null) return;
  PVector pos = new PVector(hit.x, hit.y);
  dragWalker = new Walker(nextWalkerId++, pos, pos, pos);
  dragWalker.frozen = true;
  walkers.add(dragWalker);
  dragging = true;
  tuioLog("mouse cursor id " + dragWalker.id + " at (" + nf(hit.x, 2, 2) + ", " + nf(hit.y, 2, 2) + ")");
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

// Screen point -> floor plane (y=0) hit in observation coords (x, y in meters).
// Camera basis from PeasyCam eye + lookAt (roll ignored), P3D default frustum.
PVector rayToFloor(float mx, float my) {
  float[] eye = cam.getPosition();
  float[] la = cam.getLookAt();
  double fx = la[0] - eye[0], fy = la[1] - eye[1], fz = la[2] - eye[2];
  double fl = Math.max(1e-9, Math.sqrt(fx * fx + fy * fy + fz * fz));
  fx /= fl; fy /= fl; fz /= fl;

  // right = fwd x worldUp(0,1,0); up = right x fwd
  double rx = fz * 1 - 0, ry = 0, rz = -fx; // fwd x (0,1,0) = (fz, 0, -fx)
  double rl = Math.max(1e-9, Math.sqrt(rx * rx + rz * rz));
  rx /= rl; rz /= rl;
  double ux = ry * fz - rz * fy;
  double uy = rz * fx - rx * fz;
  double uz = rx * fy - ry * fx;

  double tanV = Math.tan(PI / 6.0);
  double aspect = (double) width / height;
  double sx = ((double) mx / width - 0.5) * 2.0 * tanV * aspect;
  double sy = (0.5 - (double) my / height) * 2.0 * tanV;
  double dirx = fx + rx * sx + ux * sy;
  double diry = fy + ry * sx + uy * sy;
  double dirz = fz + rz * sx + uz * sy;

  if (Math.abs(diry) < 1e-6) return null;
  double t = -eye[1] / diry; // plane y = 0
  if (t <= 0) return null;

  double wx = eye[0] + dirx * t;
  double wz = eye[2] + dirz * t;

  double obsX = wx + ROOM_W / 2.0;
  double obsY = wz + ROOM_D / 2.0;
  if (obsX < 0 || obsX > ROOM_W || obsY < 0 || obsY > ROOM_D) return null;
  return new PVector((float) obsX, (float) obsY);
}
