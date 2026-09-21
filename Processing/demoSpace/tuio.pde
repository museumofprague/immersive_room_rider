// TUIO input tab. Receives TUIO/OSC on the port below (sender at 192.168.0.64
// must be configured to transmit UDP to this machine on that port).

import TUIO.*;

final int TUIO_PORT = 3333;
TuioProcessing tuioClient;
java.util.HashMap<Long, Integer> cursorColors = new java.util.HashMap<Long, Integer>();

void setupTuio() {
  tuioClient = new TuioProcessing(this, TUIO_PORT);
}

// called from main draw() while inside canvas.beginDraw()/endDraw()
void drawTuio(PGraphics g) {
  if (tuioClient == null) return;

  //g.noLights();
  g.strokeWeight(3);

  // objects: rotated square at normalized position
  g.stroke(255);
  g.fill(255, 120);
  for (TuioObject tobj : tuioClient.getTuioObjectList()) {
    g.pushMatrix();
    g.translate(tobj.getX() * g.width, tobj.getY() * g.height);
    g.rotate(tobj.getAngle());
    float s = g.height * 0.1;
    g.rect(-s / 2, -s / 2, s, s);
    g.popMatrix();
  }

  // cursors: circle + trail, random color per session id, 5px stroke, id label
  g.strokeWeight(10);
  //g.fill(0, 0, 0, 0);
  for (TuioCursor tcur : tuioClient.getTuioCursorList()) {
    Long key = tcur.getSessionID();
    Integer stored = cursorColors.get(key);
    color c;
    if (stored == null) {
      c = color(random(80, 255), random(80, 255), random(80, 255));
      cursorColors.put(key, c);
    } else {
      c = stored;
    }
    
    java.util.List<TuioPoint> path = tcur.getPath();
    g.stroke(255);
    for (int i = 1; i < path.size(); i++) {
      TuioPoint p0 = path.get(i - 1);
      TuioPoint p1 = path.get(i);
      g.line(p0.getX() * g.width, p0.getY() * g.height, p1.getX() * g.width, p1.getY() * g.height);
    }
    
    g.stroke(255);
    g.fill(c);
    float d = g.height * 0.05;
    float cx = tcur.getX() * g.width;
    float cy = tcur.getY() * g.height;
    g.ellipse(cx, cy, d, d);
    
    g.fill(255);
    g.textSize(g.height * 0.03);
    g.textAlign(CENTER, CENTER);
    g.text(str(tcur.getCursorID()), cx, cy);

  }
  // blobs: rotated ellipse sized by width/height
  for (TuioBlob tblb : tuioClient.getTuioBlobList()) {
    g.pushMatrix();
    g.translate(tblb.getX() * g.width, tblb.getY() * g.height);
    g.rotate(tblb.getAngle());
    g.ellipse(0, 0, tblb.getWidth() * g.width, tblb.getHeight() * g.height);
    g.popMatrix();
  }
}

void addTuioObject(TuioObject tobj) {
  println("add obj " + tobj.getSymbolID() + " " + tobj.getX() + " " + tobj.getY());
}

void updateTuioObject(TuioObject tobj) { }

void removeTuioObject(TuioObject tobj) {
  println("del obj " + tobj.getSymbolID());
}

void addTuioCursor(TuioCursor tcur) {
  println("add cur " + tcur.getCursorID() + " (" + tcur.getX() + ", " + tcur.getY() + ")");
}

void updateTuioCursor(TuioCursor tcur) { }

void removeTuioCursor(TuioCursor tcur) {
  cursorColors.remove(tcur.getSessionID());
  println("del cur " + tcur.getCursorID());
}

void addTuioBlob(TuioBlob tblb) {
  println("add blob " + tblb.getBlobID() + " (" + tblb.getX() + ", " + tblb.getY() + ")");
}

void updateTuioBlob(TuioBlob tblb) { }

void removeTuioBlob(TuioBlob tblb) {
  println("del blob " + tblb.getBlobID());
}

void refresh(TuioTime bundleTime) { redraw(); }
