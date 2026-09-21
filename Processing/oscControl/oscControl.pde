// oscControl: sends /background/0|1|2 (r g b ints) to demoSpace's OSC listener
// (see demoSpace/OSC.pde, UDP 9998). Three LazyGui color pickers, each also
// shown as a horizontal strip; a message is sent only when a color changes.

import oscP5.*;
import netP5.*;
import com.krab.lazy.*;

final String OSC_TARGET_IP = "127.0.0.1";
final int OSC_TARGET_PORT = 9998;

final String[] SURFACE_NAME = { "left wall", "floor", "right wall" };
color[] col = { color(200, 40, 40), color(40, 180, 60), color(40, 80, 220) };
color[] sentCol = new color[SURFACE_NAME.length];

OscP5 osc;
NetAddress dest;
LazyGui gui;

void settings() {
  size(640, 360, P2D);
}

void setup() {
  gui = new LazyGui(this);
  osc = new OscP5(this, 9999); // receive side unused; we only send
  dest = new NetAddress(OSC_TARGET_IP, OSC_TARGET_PORT);
  for (int i = 0; i < col.length; i++) sentCol[i] = col[i];
  println("sending /background/N to " + OSC_TARGET_IP + ":" + OSC_TARGET_PORT);
}

void draw() {
  for (int i = 0; i < SURFACE_NAME.length; i++) {
    col[i] = gui.colorPicker("Background " + SURFACE_NAME[i], col[i]).hex;
    if (col[i] != sentCol[i]) {
      sendBackground(i, col[i]);
      sentCol[i] = col[i];
    }
  }

  for (int i = 0; i < SURFACE_NAME.length; i++) {
    noStroke();
    fill(col[i]);
    rect(0, i * height / SURFACE_NAME.length, width, height / SURFACE_NAME.length);
  }

  gui.draw();
}

void sendBackground(int surface, color c) {
  OscMessage m = new OscMessage("/background/" + surface);
  m.add(int(red(c)));
  m.add(int(green(c)));
  m.add(int(blue(c)));
  osc.send(m, dest);
  println("sent /background/" + surface + " " + hex(c, 6));
}
