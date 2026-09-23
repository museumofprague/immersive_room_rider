import spout.*;
import TUIO.*;

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

PGraphics canvas2D;  // P2D shared space, Spout source
Spout sender;

String OS; // "windows", "macos", "linux"
final String SENDER_NAME = "processing_demosimple";

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

  if (OS.equals("windows")) {
    sender = new Spout(this);
    sender.setSenderName(SENDER_NAME);
  }

  setupTuio();
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

void draw() {
  float t = millis() * 0.001;

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

  // 2D DEMO: a circle moving across all three regions. Its position is in
  // shared texture space, so it visibly crosses the borders.
  canvas2D.noFill();
  canvas2D.stroke(255, 220);
  canvas2D.strokeWeight(textureHeight * 0.01);
  float circR = textureHeight * 0.08;
  float cx = (0.5 + 0.40 * sin(t * 0.23 + 2.0)) * textureWidth;
  float cy = (0.5 + 0.40 * sin(t * 0.13 + 1.0)) * textureHeight;
  canvas2D.ellipse(cx, cy, circR * 2, circR * 2);
  canvas2D.noStroke();

  drawTuio(canvas2D);

  canvas2D.endDraw();

  // publish the merged texture via Spout (Windows only)
  if (OS.equals("windows")) {
    try {
      sender.sendTexture(canvas2D);
    } catch (Exception e) {
      println("Spout publish failed: " + e);
    }
  }

  // scaled preview in the window
  background(30);
  image(canvas2D, 0, 0, width, height);

  // source hint, top-left
  fill(255);
  noStroke();
  textAlign(LEFT, TOP);
  textSize(14);
  if (OS.equals("windows")) text("Spout: " + SENDER_NAME, 10, 8);
  else text("Spout unavailable on " + OS, 10, 8);

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
