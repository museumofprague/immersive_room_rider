import spout.*;
import TUIO.*;

// A single merged output texture: left wall / floor / right wall stacked vertically.
// Regions are sized by PHYSICAL extent, not source pixel count: the floor has fewer
// projector pixels but spans the same physical width as the walls, so its projectors
// have a coarser pixel pitch. Layout uses one common physical scale -> surfaces form a
// continuous canvas and content crosses region borders without size jumps.
// The longest side of the texture is capped at MAX_SIDE px. Pixera maps each region
// to its physical surface later; here we only bake one texture and draw white borders.

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

PGraphics canvas;
Spout sender;

String OS; // "windows", "macos", "linux"

void setup() {
  size(1280, 720, P2D);

  String osName = System.getProperty("os.name").toLowerCase();
  if (osName.contains("win")) OS = "windows";
  else if (osName.contains("mac")) OS = "macos";
  else OS = "linux";
  println("OS: " + OS);

  surface.setLocation(10, 10);
  pixelDensity(1);

  computeLayout();

  canvas = createGraphics(textureWidth, textureHeight, P2D);

  if (OS.equals("windows")) {
    sender = new Spout(this);
    sender.setSenderName("processing_demospace");
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
  canvas.beginDraw();
  canvas.background(0);
  canvas.noStroke();

  for (int i = 0; i < PROJ_PX.length; i++) {
    canvas.pushMatrix();
    canvas.translate(regX[i], regY[i]);

    // region background
    canvas.fill(regColor[i]);
    canvas.rect(0, 0, regW[i], regH[i]);

    // demo content: rotating box, sized to fit inside the region
    canvas.lights();
    canvas.pushMatrix();
    canvas.translate(regW[i] / 2.0, regH[i] / 2.0);
    canvas.rotateX(frameCount * 0.01);
    canvas.rotateY(frameCount * 0.01);
    canvas.fill(255);
    canvas.box(min(regW[i], regH[i]) * 0.4);
    canvas.popMatrix();

    canvas.popMatrix();
  }

  // white borders on region boundaries (drawn last, on top)
  canvas.noFill();
  canvas.stroke(255);
  canvas.strokeWeight(2);
  for (int i = 0; i < PROJ_PX.length; i++) {
    canvas.rect(regX[i], regY[i], regW[i], regH[i]);
  }
  canvas.noStroke();

  drawTuio(canvas);

  canvas.endDraw();

  if (OS.equals("windows")) {
    sender.sendTexture(canvas);
  }

  // scaled preview in the window
  background(30);
  image(canvas, 0, 0, width, height);
}
