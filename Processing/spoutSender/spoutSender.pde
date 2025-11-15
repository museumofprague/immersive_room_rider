import spout.*;

PGraphics[] canvas;
Spout[] senders;

color[] colors = new color[3];

void setup() {

  size(1280, 720, P2D);
  surface.setLocation(10, 10);
  pixelDensity(1);
  // Create graphics objects for the senders
  canvas = new PGraphics[3];
  canvas[0] = createGraphics(9974, 1929, P3D);
  canvas[1] = createGraphics(6830, 2160, P3D);
  canvas[2] = createGraphics(9974, 1929, P3D);

  colors[0] = color(255, 0, 0);
  colors[1] = color(0, 255, 0);
  colors[2] = color(0, 0, 255);

  // Create Spout senders to send frames out.
  senders = new Spout[3];
  senders[0] = new Spout(this);
  senders[0].setSenderName("processing_left_wall");

  senders[1] = new Spout(this);
  senders[1].setSenderName("processing_floor");

  senders[2] = new Spout(this);
  senders[2].setSenderName("processing_right_wall");
}

void draw() {
  for (int i = 0; i < 3; i++) {
    canvas[i].beginDraw();
    canvas[i].background(colors[i]);
    canvas[i].lights();
    canvas[i].translate(canvas[i].width/2, canvas[i].height/2);
    canvas[i].rotateX(frameCount * 0.01);
    canvas[i].rotateY(frameCount * 0.01);
    canvas[i].box(150);
    canvas[i].endDraw();
    senders[i].sendTexture(canvas[i]);
    image(canvas[i], 640 * (i % 2), 360 * (i / 2), 640, 360);
  }
}
