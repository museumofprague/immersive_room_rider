import spout.*;
import TUIO.*;
import codeanticode.syphon.*;
import cz.vleischner.ndi.*;

// A single merged output texture: left wall / floor / right wall stacked vertically.
// Regions are sized by PHYSICAL extent, not source pixel count: the floor has fewer
// projector pixels but spans the same physical width as the walls, so its projectors
// have a coarser pixel pitch. Layout uses one common physical scale -> surfaces form a
// continuous canvas and content crosses region borders without size jumps.
// The longest side of the texture is capped at MAX_SIDE px. Pixera maps each region
// to its physical surface later; here we only bake one texture and draw white borders.

//in Pixera server set 3 surfaces as left wall: y offset 2520
//right wall - fx flip horizontal + vertical, y offset 2520
//floor - keep as is, set live source to Spout

final int MAX_SIDE = 4096;

// source content sizes in projector pixels (width x height)
final int[][] PROJ_PX = {
  { 9974, 1929 }, // left wall
  { 6830, 2160 }, // floor: coarser projectors, same physical width as the walls
  { 9974, 1929 }, // right wall
};

// relative physical size of one projector pixel per surface, in wall-px units.
// Assumption: projector pixels are square per surface, so the pitch factor derived
// from the width also applies to the height.
final float[] PITCH = {
  1.0,
  (float) PROJ_PX[0][0] / PROJ_PX[1][0], // floor px are physically 1.46x wall px
  1.0,
};
final String[] REGION_NAME = { "left_wall", "floor", "right_wall" };

// region rectangle in texture space + background color (filled by computeLayout)
int[] regX, regY, regW, regH;
color[] regColor = { color(200, 40, 40), color(40, 180, 60), color(40, 80, 220) };

PGraphics canvas2D;  // P2D shared space
PGraphics canvas3D;  // P3D offscreen for 3D content
Spout sender;

// Syphon (macOS) reached via reflection; import at top only puts the library
// jar on the classpath (sketch needs the Syphon contrib installed to compile)
Object syphonServer;
java.lang.reflect.Method syphonSendImage;

String OS; // "windows", "macos", "linux"
final String SENDER_NAME = "processing_demospace";

// texture sharing transport: GPU (Spout/Syphon) or NDI, toggled with 'n'
boolean useNDI = false;
NDIP5Sender ndiSender;
NDIP5VideoFrame ndiFrame;
// double buffer: one is in flight with the async sender while the other is filled
java.nio.ByteBuffer[] ndiData = new java.nio.ByteBuffer[2];
java.nio.IntBuffer[] ndiDataInts = new java.nio.IntBuffer[2];
int ndiBufferIndex = 0;
int fpsFrames = 0;
long fpsLastMillis = 0;
double fpsShown = 0;

void setup() {
  size(1280, 720, P2D);

  String osName = System.getProperty("os.name").toLowerCase();
  if (osName.contains("win")) OS = "windows";
  else if (osName.contains("mac")) OS = "macos";
  else OS = "linux";
  println("OS: " + OS);

  surface.setLocation(10, 10);

  computeLayout();

  // shared 2D canvas (P2D): regions, 2D content, borders, TUIO, Spout source
  canvas2D = createGraphics(textureWidth, textureHeight, P2D);
  // 3D content buffer (P3D): rendered separately, composited into canvas via image()
  canvas3D = createGraphics(textureWidth, textureHeight, P3D);

  if (OS.equals("windows")) {
    sender = new Spout(this);
    sender.setSenderName(SENDER_NAME);
  } else if (OS.equals("macos")) {
    setupSyphonSender();
  }

  setupTuio();
  setupOSC();
}

// one shared physical scale for every region -> continuous surface, correct aspect
int textureWidth;
int textureHeight;
void computeLayout() {
  float maxPhysW = 0;
  float stackPhysH = 0;
  for (int i = 0; i < PROJ_PX.length; i++) {
    maxPhysW = max(maxPhysW, PROJ_PX[i][0] * PITCH[i]);
    stackPhysH += PROJ_PX[i][1] * PITCH[i];
  }
  float scale = (float) MAX_SIDE / maxPhysW; // texture px per physical unit, longest side = MAX_SIDE

  textureWidth  = round(maxPhysW * scale);
  textureHeight = round(stackPhysH * scale);

  regX = new int[PROJ_PX.length];
  regY = new int[PROJ_PX.length];
  regW = new int[PROJ_PX.length];
  regH = new int[PROJ_PX.length];

  int y = 0;
  for (int i = 0; i < PROJ_PX.length; i++) {
    regW[i] = round(PROJ_PX[i][0] * PITCH[i] * scale);
    regH[i] = round(PROJ_PX[i][1] * PITCH[i] * scale);
    regX[i] = (textureWidth - regW[i]) / 2; // center horizontally
    regY[i] = y;
    y += regH[i];
  }
  for (int i = 0; i < PROJ_PX.length; i++) {
    println(REGION_NAME[i] + ": " + regX[i] + "," + regY[i] + " " + regW[i] + "x" + regH[i]);
  }
}

void setupSyphonSender() {
  try {
    Class<?> c = Class.forName("codeanticode.syphon.SyphonServer");
    syphonServer = c.getConstructor(PApplet.class, String.class).newInstance(this, SENDER_NAME);
    syphonSendImage = c.getMethod("sendImage", PImage.class);
    println("Syphon server started: " + SENDER_NAME);
  } catch (Throwable e) {
    Throwable c = e.getCause() != null ? e.getCause() : e;
    c.printStackTrace();
    println("Syphon init failed: " + c);
    syphonSendImage = null;
  }
}

// publish the merged texture on the selected transport
void publishTexture() {
  if (useNDI) {
    publishNDI();
    return;
  }
  try {
    if (OS.equals("windows")) sender.sendTexture(canvas2D);
    else if (OS.equals("macos") && syphonSendImage != null) syphonSendImage.invoke(syphonServer, canvas2D);
  } catch (Exception e) {
    Throwable c = e.getCause() != null ? e.getCause() : e;
    println("texture publish failed: " + c);
  }
}

// NDI is created lazily on first use so the source only appears when wanted
void initNDISender() {
  try {
    ndiSender = new NDIP5Sender(SENDER_NAME);
    ndiFrame = new NDIP5VideoFrame();
    ndiFrame.setResolution(textureWidth, textureHeight);
    ndiFrame.setFourCCType(NDIP5FrameFourCCType.BGRA);
    ndiFrame.setFrameRate(30, 1);
    ndiFrame.setLineStride(textureWidth * 4);
    for (int i = 0; i < 2; i++) {
      ndiData[i] = java.nio.ByteBuffer.allocateDirect(textureWidth * textureHeight * 4)
                 .order(java.nio.ByteOrder.LITTLE_ENDIAN);
      ndiDataInts[i] = ndiData[i].asIntBuffer();
    }
    println("NDI sender started: " + SENDER_NAME);
  } catch (Throwable e) {
    println("NDI init failed: " + e);
    ndiSender = null;
  }
}

// PImage pixels are 0xAARRGGBB ints = BGRA bytes little-endian: direct copy.
// Async submit returns immediately; alternate buffers so the in-flight one
// is never overwritten while NDI still owns it.
void publishNDI() {
  if (ndiSender == null) return;
  canvas2D.loadPixels();
  ndiBufferIndex ^= 1;
  ndiDataInts[ndiBufferIndex].position(0);
  ndiDataInts[ndiBufferIndex].put(canvas2D.pixels);
  ndiFrame.setData(ndiData[ndiBufferIndex]);
  ndiSender.sendVideoFrameAsync(ndiFrame);
}

void keyPressed() {
  if (key == 'n' || key == 'N') {
    useNDI = !useNDI;
    if (useNDI && ndiSender == null) initNDISender();
  }
}

void stop() {
  if (ndiFrame != null) ndiFrame.close();
  if (ndiSender != null) ndiSender.close();
}

void draw() {
  float t = millis() * 0.001;

  // ================================================================
  // 3D DEMO: render the rotating box in its own P3D buffer, isolated
  // on a transparent background. Keeping it in a separate buffer means
  // the 2D region fills (drawn in P2D) can never depth-clip / occlude
  // the box corners. We composite it onto the shared canvas with image().
  // ================================================================
  canvas3D.beginDraw();
  canvas3D.clear();                 // transparent, no background fill
  canvas3D.lights();
  canvas3D.noStroke();
  // explicit frustum: default far plane is too tight for this buffer size
  float fov = PI / 3.0;
  float eyeZ = (textureHeight / 2.0) / tan(fov / 2.0);
  canvas3D.camera(textureWidth / 2.0, textureHeight / 2.0, eyeZ,
                textureWidth / 2.0, textureHeight / 2.0, 0, 0, 1, 0);
  canvas3D.perspective(fov, textureWidth / (float) textureHeight, 1, eyeZ * 4);
  float boxS = textureHeight * 0.15;
  canvas3D.pushMatrix();
  canvas3D.translate((0.5 + 0.42 * sin(t * 0.31)) * textureWidth,
                   (0.5 + 0.42 * sin(t * 0.17)) * textureHeight);
  canvas3D.rotateX(t * 0.7);
  canvas3D.rotateY(t * 0.9);
  canvas3D.fill(255);
  canvas3D.box(boxS);
  canvas3D.popMatrix();
  canvas3D.endDraw();

  // ================================================================
  // SHARED 2D CANVAS (P2D): the merged wall/floor/wall space.
  // Everything here is flat 2D and shares one continuous surface, so
  // content flows across region borders without a size jump.
  // ================================================================
  canvas2D.beginDraw();
  canvas2D.background(0);
  canvas2D.noStroke();

  // per-region background color: shows wall / floor / wall boundaries
  for (int i = 0; i < PROJ_PX.length; i++) {
    canvas2D.fill(regColor[i]);
    canvas2D.rect(regX[i], regY[i], regW[i], regH[i]);
  }

  // region junctions: two white horizontal lines, behind the moving content.
  // weight 6: at 2 px the line is ~1 texel after layout rounding and gets
  // averaged away when the texture is minified
  canvas2D.stroke(255);
  canvas2D.strokeWeight(6);
  for (int i = 1; i < PROJ_PX.length; i++) {
    float jy = regY[i];
    canvas2D.line(0, jy, textureWidth, jy);
  }
  canvas2D.noStroke();

  // 2D DEMO: a circle moving across all three regions. Like the box, its
  // position is in shared texture space, so it visibly crosses the borders.
  canvas2D.noFill();
  canvas2D.stroke(255, 220);
  canvas2D.strokeWeight(textureHeight * 0.01);
  float circR = textureHeight * 0.08;
  float cx = (0.5 + 0.40 * sin(t * 0.23 + 2.0)) * textureWidth;
  float cy = (0.5 + 0.40 * sin(t * 0.13 + 1.0)) * textureHeight;
  canvas2D.ellipse(cx, cy, circR * 2, circR * 2);
  canvas2D.noStroke();

  // composite the 3D box on top of the 2D content
  canvas2D.image(canvas3D, 0, 0);

  drawTuio(canvas2D);

  canvas2D.endDraw();

  publishTexture();

  // scaled preview in the window
  background(30);
  image(canvas2D, 0, 0, width, height);

  // transport hint, top-left
  fill(255);
  noStroke();
  textAlign(LEFT, TOP);
  textSize(14);
  String gpuName = OS.equals("windows") ? "Spout" : "Syphon";
  text("[n] sharing: " + (useNDI ? "NDI '" + SENDER_NAME + "'" : gpuName + " (GPU)"), 10, 8);

  // fps, top-right (rolling 1s average)
  fpsFrames++;
  if (millis() - fpsLastMillis >= 1000) {
    fpsShown = fpsFrames * 1000.0 / (millis() - fpsLastMillis);
    fpsLastMillis = millis();
    fpsFrames = 0;
  }
  textAlign(RIGHT, TOP);
  text(nf((float) fpsShown, 2, 0) + " fps", width - 10, 8);
}
