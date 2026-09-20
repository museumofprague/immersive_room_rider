// TUIO input tab. Receives TUIO/OSC on the port below (sender at 192.168.0.64
// must be configured to transmit UDP to this machine on that port).

import TUIO.*;

final int TUIO_PORT = 2112;
TuioProcessing tuioClient;

void setupTuio() {
  tuioClient = new TuioProcessing(this, TUIO_PORT);
}

// called from main draw() while inside canvas.beginDraw()/endDraw()
void drawTuio(PGraphics g) {
  if (tuioClient == null) return;

  g.noLights();
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

  // cursors: circle + trail
  g.stroke(255);
  g.fill(0, 0, 0, 0);
  for (TuioCursor tcur : tuioClient.getTuioCursorList()) {
    float d = g.height * 0.05;
    g.ellipse(tcur.getX() * g.width, tcur.getY() * g.height, d, d);
    java.util.List<TuioPoint> path = tcur.getPath();
    if (path.size() > 1) {
      g.strokeWeight(1);
      for (int i = 1; i < path.size(); i++) {
        TuioPoint p0 = path.get(i - 1);
        TuioPoint p1 = path.get(i);
        g.line(p0.getX() * g.width, p0.getY() * g.height, p1.getX() * g.width, p1.getY() * g.height);
      }
      g.strokeWeight(3);
    }
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
