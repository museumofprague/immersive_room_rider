/*
This sketch demonstrates how to control Resolume Arena 
videomapping software via OSC fromn different PC.
Addjust IP:port to your target
Both PCs must be on the same network without VPN on
*/
import netP5.*;
import oscP5.*;

// ---------------------------------------------------------------------------
// config
// ---------------------------------------------------------------------------
final String HOST = "10.141.240.65";
final int PORT = 7000;

final int LAYER_MIN = 1;
final int LAYER_MAX = 5;
final int START_CLIP = 1;

// Resolume event controls fire on the rising edge: 1, then 0 again
final int RELEASE_DELAY_MS = 60;

// pixel density of the sketch surface. 0 follows the display, which is right
// for most machines. If type still looks jagged because Windows is scaling the
// window bitmap, set this to 2 to render at double resolution and let the OS
// downsample.
final int DENSITY = 0;

// ---------------------------------------------------------------------------
// osc state
// ---------------------------------------------------------------------------
OscP5 oscP5;
NetAddress myRemoteLocation;

int currentLayer = 1;
int currentClip = START_CLIP;
String lastSent = "ready";

// last key we acted on, so OS key auto-repeat does not resend while held
char lastKey = 0;
int lastKeyCode = -1;

ArrayList<Pending> pendingReleases = new ArrayList<Pending>();

// ---------------------------------------------------------------------------
// type
// ---------------------------------------------------------------------------
// logical pixel sizes used by the layout
final int LABEL = 13;
final int VALUE = 14;
final int TITLE = 46;

PFont fLabel;
PFont fValue;
PFont fTitle;

// ---------------------------------------------------------------------------
// palette
// ---------------------------------------------------------------------------
final int BG   = 0;     // black
final int INK  = 255;   // primary text
final int DIM  = 118;   // secondary text
final int RULE = 38;    // hairlines
final int EDGE = 74;    // key chips

// ---------------------------------------------------------------------------
// layout
// ---------------------------------------------------------------------------
final int M = 36;       // page margin
final int CHIP_W = 78;
final int CHIP_H = 24;
final int ROW = 34;     // legend row pitch

// resolved from DENSITY in setup, also used to pick the glyph bake scale
int density = 1;

void setup() {
  size(520, 520);
  // render at the display's native scale so geometry is not upscaled by the OS
  density = (DENSITY == 0) ? displayDensity() : DENSITY;
  pixelDensity(density);
  smooth(8);
  frameRate(30);

  loadFonts();

  // OSC receiver, so Resolume can talk back to this sketch
  oscP5 = new OscP5(this, 7001);

  // where we send to
  myRemoteLocation = new NetAddress(HOST, PORT);
}

// Processing caches glyph bitmaps at the size the PFont was created at and
// blits them scaled to textSize, so the bake size is what decides sharpness.
// Baking at 2x the logical size is smoothed down on a 1x display and is an
// exact 1:1 match for the device pixels on a 2x display.
void loadFonts() {
  String regular  = fontFile("NunitoSans-Regular.ttf", "Nunito Sans");
  String semibold = fontFile("NunitoSans-SemiBold.ttf", "Nunito Sans");
  int scale = max(2, density);

  fLabel = createFont(regular, LABEL * scale, true);
  fValue = createFont(regular, VALUE * scale, true);
  fTitle = createFont(semibold, TITLE * scale, true);
}

String fontFile(String file, String systemName) {
  if (dataFile(file).exists()) {
    return file;
  }
  println("missing data/" + file + ", falling back to the system font " + systemName);
  return systemName;
}

void draw() {
  flushReleases();

  background(BG);
  drawCrosshair();

  // header
  textFont(fLabel, LABEL);
  fill(DIM);
  text("RESOLUME / OSC REMOTE", M, 54);
  hairline(74);

  // readout
  textFont(fTitle, TITLE);
  fill(INK);
  text("LAYER " + currentLayer, M, 128);

  textFont(fLabel, LABEL);
  fill(DIM);
  text("CLIP " + currentClip + " PLAYING", M, 154);

  textAlign(RIGHT, BASELINE);
  text("MOUSE " + (mouseX - width / 2) + " / " + (mouseY - height / 2), width - M, 154);
  textAlign(LEFT, BASELINE);

  hairline(184);

  // key legend
  int y = 218;
  legendRow(y, "SPACE", "Play clip " + START_CLIP); y += ROW;
  legendRow(y, "0 - 9", "Play clip 0 - 9");         y += ROW;
  legendRow(y, "UP",    "Layer +1");                y += ROW;
  legendRow(y, "DOWN",  "Layer -1");                y += ROW;
  legendRow(y, "S",     "Stop / clear layer");      y += ROW;
  legendRow(y, "D",     "Stop all layers");

  hairline(430);

  // footer
  textFont(fLabel, LABEL);
  fill(DIM);
  text("LAST SENT", M, 458);

  textFont(fValue, VALUE);
  fill(INK);
  text(lastSent, M, 476);

  textFont(fLabel, LABEL);
  fill(DIM);
  text(HOST + ":" + PORT + "     LAYERS " + LAYER_MIN + " - " + LAYER_MAX, M, 502);
}

// ---------------------------------------------------------------------------
// drawing helpers
// ---------------------------------------------------------------------------
void hairline(float y) {
  stroke(RULE);
  strokeWeight(1);
  line(M, y, width - M, y);
  noStroke();
}

void legendRow(int baseline, String keyLabel, String desc) {
  // key chip
  stroke(EDGE);
  strokeWeight(1);
  noFill();
  rect(M, baseline - 17, CHIP_W, CHIP_H, 6);
  noStroke();

  textFont(fLabel, LABEL);
  fill(INK);
  textAlign(CENTER, BASELINE);
  text(keyLabel, M + CHIP_W / 2, baseline);
  textAlign(LEFT, BASELINE);

  // description
  fill(DIM);
  text(desc, M + CHIP_W + 22, baseline);
}

void drawCrosshair() {
  stroke(30);
  strokeWeight(1);
  line(mouseX, 0, mouseX, height);
  line(0, mouseY, width, mouseY);

  noFill();
  stroke(210);
  ellipse(mouseX, mouseY, 9, 9);
  noStroke();
}

// ---------------------------------------------------------------------------
// input
// ---------------------------------------------------------------------------
void keyPressed() {
  if (key == CODED) {
    // ignore the OS auto-repeat of an arrow that is being held down
    if (keyCode == lastKeyCode) {
      return;
    }
    lastKeyCode = keyCode;

    if (keyCode == UP) {
      changeLayer(1);
    }
    else if (keyCode == DOWN) {
      changeLayer(-1);
    }
    return;
  }

  // ignore the OS auto-repeat of a key that is being held down
  if (key == lastKey) {
    return;
  }
  lastKey = key;

  if (key == ' ') {
    playClip(START_CLIP);
  }
  else if (key == 's' || key == 'S') {
    stopLayer();
  }
  else if (key == 'd' || key == 'D') {
    // stop every layer, handy to confirm that event triggers work at all
    trigger("/composition/disconnectall", "disconnect all layers");
  }
  else if (key >= '0' && key <= '9') {
    // clip 0 does not exist in Resolume, so 0 is used for clip 10
    int digit = key - '0';
    playClip(digit == 0 ? 10 : digit);
  }
}

void keyReleased() {
  lastKey = 0;
  lastKeyCode = -1;
}

// walk the target layer up or down and follow it in Resolume's selection
void changeLayer(int direction) {
  int next = constrain(currentLayer + direction, LAYER_MIN, LAYER_MAX);

  if (next == currentLayer) {
    lastSent = "layer already at " + (direction > 0 ? "top" : "bottom") + " (" + currentLayer + ")";
    return;
  }

  currentLayer = next;
  trigger("/composition/layers/" + currentLayer + "/select", "select layer " + currentLayer);
}

// ---------------------------------------------------------------------------
// osc
// ---------------------------------------------------------------------------
// connect a clip on the current layer -> starts its playback
void playClip(int clip) {
  OscMessage msg = new OscMessage("/composition/layers/" + currentLayer + "/clips/" + clip + "/connect");
  msg.add(1);
  oscP5.send(msg, myRemoteLocation);

  currentClip = clip;
  lastSent = msg.addrPattern() + "  1";
}

// eject the playing clip -> stops playback
void stopLayer() {
  trigger("/composition/layers/" + currentLayer + "/clear", "clear layer " + currentLayer);
}

// event controls latch on 1, so send 1 now and the matching 0 shortly after
void trigger(String addr, String note) {
  OscMessage on = new OscMessage(addr);
  on.add(1);

  OscMessage off = new OscMessage(addr);
  off.add(0);

  oscP5.send(on, myRemoteLocation);
  pendingReleases.add(new Pending(off, millis() + RELEASE_DELAY_MS));

  lastSent = addr + "  1 / 0";
}

void flushReleases() {
  for (int i = pendingReleases.size() - 1; i >= 0; i--) {
    if (millis() >= pendingReleases.get(i).due) {
      oscP5.send(pendingReleases.get(i).msg, myRemoteLocation);
      pendingReleases.remove(i);
    }
  }
}

void oscEvent(OscMessage theOscMessage) {
  println("received: " + theOscMessage.addrPattern() + " " + theOscMessage.typetag());
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------
// a message waiting to be sent at due (millis)
class Pending {
  OscMessage msg;
  int due;

  Pending(OscMessage msg, int due) {
    this.msg = msg;
    this.due = due;
  }
}
