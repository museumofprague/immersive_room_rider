// mockupTuio: TUIO 1.1 server simulation for the tracked room.
//
// Sends /tuio/2Dcur cursor frames (TUIO 1.0 addressing) over UDP/OSC, mimicking the Pharus tracker:
// people enter through doors, wander the space, and leave. Coordinates are
// normalized (0..1) over the tracking space defined in pharus/config.xml
// (observationspace left=0 right=21.842 lower=0 upper=5.938, meters).
//
// libTUIO.jar (in code/) ships no TuioServer class, so raw TUIO/OSC messages
// are built with the bundled com.illposed.osc classes.
//
// Receiver side: demoSpace listens on TUIO_PORT; point its sender target at
// this machine, or run both on one host and send TUIO to that port.

import com.illposed.osc.*;
import java.net.InetAddress;

// --- tracking space (pharus/config.xml, meters) ---
final float SPACE_W = 21.842;
final float SPACE_H = 5.938;

// --- TUIO output ---
final String TUIO_DEST_IP = "127.0.0.1";
final int TUIO_PORT = 3333;
final String TUIO_ADDR = "/tuio/2Dcur"; // TUIO 1.0 addr: installed lib has no 2cl handler

// People walk on the floor, which in demoSpace's merged texture occupies rows
// 792..2087 of 2880 (full width). Like the original server, positions are
// pre-mapped so the receiver's plain x*w, y*h mapping lands them on the floor.
// Observation y=SPACE_H (upper edge, wall junction) -> floor top row.
final float FLOOR_TUIO_Y0 = 792.0 / 2880.0;
final float FLOOR_TUIO_Y1 = 2087.0 / 2880.0;

OSCPortOut tuioSender;
int frameId = 0;

// doors: left edge upper third, and bottom edge 5% in from the right edge
final PVector DOOR_LEFT  = new PVector(0, SPACE_H * 5.0 / 6.0);
final PVector DOOR_RIGHT = new PVector(SPACE_W * 0.95, 0);

ArrayList<Walker> walkers = new ArrayList<Walker>();
int nextWalkerId = 0;
float nextSpawnAt = 0;

void setup() {
  size(1200, 327); // 1:100 scale of the space, y flipped for screen
  frameRate(30);
  try {
    tuioSender = new OSCPortOut(InetAddress.getByName(TUIO_DEST_IP), TUIO_PORT);
  } catch (Exception e) {
    println("TUIO sender init failed: " + e);
    exit();
  }
  println("mockupTuio -> " + TUIO_DEST_IP + ":" + TUIO_PORT + " (" + TUIO_ADDR + ")");
}

void draw() {
  float dt = 1.0 / frameRate;

  // spawn people periodically, max 4 at a time
  if (millis() > nextSpawnAt && walkers.size() < 4) {
    spawnWalker();
    nextSpawnAt = millis() + random(1500, 4000);
  }

  // update people, remove those that left the space
  for (int i = walkers.size() - 1; i >= 0; i--) {
    Walker w = walkers.get(i);
    w.update(dt);
    if (w.done) {
      walkers.remove(i);
      println("leave id " + w.id);
    }
  }

  sendTuioFrame();
  drawTopView();
}

void spawnWalker() {
  boolean enterLeft = random(1) < 0.5;
  PVector inDoor  = enterLeft ? DOOR_LEFT  : DOOR_RIGHT;
  PVector outDoor = enterLeft ? DOOR_RIGHT : DOOR_LEFT;
  // spawn slightly inside the room, aim at a mid-point before exiting
  PVector start = new PVector(inDoor.x + (enterLeft ? 0.4f : 0), inDoor.y + (enterLeft ? 0 : 0.4f));
  PVector mid = new PVector(random(2, SPACE_W - 2), random(1, SPACE_H - 1));
  Walker w = new Walker(nextWalkerId++, start, mid, outDoor);
  walkers.add(w);
  println("enter id " + w.id + " at (" + start.x + ", " + start.y + ")");
}

// --- TUIO 1.1 messages ---

void sendTuioFrame() {
  if (tuioSender == null) return;
  try {
    // alive list every frame: any id missing from it gets removed by clients,
    // so walkers that left the room vanish on the receiver (like the real server)
    sendAlive();
    for (Walker w : walkers) {
      tuioSender.send(new OSCMessage(TUIO_ADDR, new Object[] {
        "set", w.id, w.nx(), w.ny(), w.nvx(), w.nvy(), 0.0f
      }));
    }
    tuioSender.send(msg("fseq", frameId));
  } catch (Exception e) {
    println("TUIO send failed: " + e);
  }
  frameId++;
}

void sendAlive() {
  Object[] args = new Object[walkers.size() + 1];
  args[0] = "alive";
  for (int i = 0; i < walkers.size(); i++) args[i + 1] = walkers.get(i).id;
  try {
    tuioSender.send(new OSCMessage(TUIO_ADDR, args));
  } catch (Exception e) {
    println("TUIO send failed: " + e);
  }
}

OSCMessage msg(String what, int frame) {
  return new OSCMessage(TUIO_ADDR, new Object[] { what, frame });
}

// --- people ---

class Walker {
  int id;
  float x, y;          // meters
  float vx, vy;        // m/s (TUIO payload)
  float speed;         // walking speed m/s
  float phase;
  PVector mid, exitDoor;
  boolean reachedMid;
  boolean done;

  Walker(int id, PVector start, PVector mid, PVector exitDoor) {
    this.id = id;
    this.x = start.x;
    this.y = start.y;
    this.mid = mid;
    this.exitDoor = exitDoor;
    speed = random(0.9, 1.5);
    phase = random(TWO_PI);
  }

  void update(float dt) {
    // one-way path: entry -> mid (latched once reached) -> exit door
    if (!reachedMid && dist(x, y, mid.x, mid.y) < 0.5) reachedMid = true;
    PVector target = reachedMid ? exitDoor : mid;

    float dx = target.x - x;
    float dy = target.y - y;
    float d = max(0.001, sqrt(dx * dx + dy * dy));
    // walking wobble: steer perpendicular, scaled down when close to target
    float wobble = sin(millis() * 0.002 * speed + phase) * 0.1 * min(1, d);
    vx = (dx / d + wobble * (-dy / d)) * speed;
    vy = (dy / d + wobble * ( dx / d)) * speed;
    x += vx * dt;
    y += vy * dt;

    // leave when at/past the exit door, or out of space bounds
    if (reachedMid && dist(x, y, exitDoor.x, exitDoor.y) < 0.4) done = true;
    if (x < -0.5 || x > SPACE_W + 0.5 || y < -0.5 || y > SPACE_H + 0.5) done = true;
  }

  // normalized TUIO coordinates, mapped into the floor band (see FLOOR_TUIO_Y*)
  float nx()  { return x / SPACE_W; }
  float ny()  { return FLOOR_TUIO_Y0 + (1.0 - y / SPACE_H) * (FLOOR_TUIO_Y1 - FLOOR_TUIO_Y0); }
  // velocities in the same normalized units (y axis is flipped by the mapping)
  float nvx() { return vx / SPACE_W; }
  float nvy() { return -vy / SPACE_H * (FLOOR_TUIO_Y1 - FLOOR_TUIO_Y0); }
}

// --- top view debug ---

void drawTopView() {
  background(20);
  pushMatrix();
  scale((float) width / SPACE_W);

  noFill();
  stroke(90);
  strokeWeight(0.05f);
  rect(0, 0, SPACE_W, SPACE_H);

  // doors (y flipped for screen coords, same as walkers)
  stroke(120, 120, 0);
  strokeWeight(0.15f);
  float dl = SPACE_H - DOOR_LEFT.y;
  float dr = SPACE_H - DOOR_RIGHT.y;
  line(DOOR_LEFT.x, dl - 0.6f, DOOR_LEFT.x, dl + 0.6f);
  line(DOOR_RIGHT.x - 0.6f, dr, DOOR_RIGHT.x + 0.6f, dr);

  // people
  noStroke();
  for (Walker w : walkers) {
    fill(255);
    circle(w.x, SPACE_H - w.y, 0.7f); // flip y for screen coords
  }
  popMatrix();

  fill(200);
  textSize(12);
  text("walkers: " + walkers.size() + "   frame: " + frameId, 8, height - 8);
}
