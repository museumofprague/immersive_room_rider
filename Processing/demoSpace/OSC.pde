// OSC input: /background/0|1|2 with three ints (r g b) recolors the
// corresponding region (left wall / floor / right wall) of the merged texture.
// Listens on UDP 9998 (sender example: oscControl sketch).

import oscP5.*;

OscP5 oscIn;

void setupOSC() {
  oscIn = new OscP5(this, 9998);
}

void oscEvent(OscMessage m) {
  for (int i = 0; i < PROJ_PX.length; i++) {
    if (m.checkAddrPattern("/background/" + i) && m.checkTypetag("iii")) {
      regColor[i] = color(m.get(0).intValue(), m.get(1).intValue(), m.get(2).intValue());
      println("OSC background " + REGION_NAME[i] + ": " + hex(regColor[i], 6));
    }
  }
}
