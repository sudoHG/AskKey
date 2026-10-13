// The room the objects reflect: white walls, a pale desk, and a tall window
// to the back left, the same window whose light falls across the desk. It
// is rendered once into a prefiltered environment map at load; nothing in
// it is drawn per frame.
import * as THREE from "three";

export function daylightEnvironment(renderer) {
  const room = new THREE.Scene();
  const box = new THREE.BoxGeometry(1, 1, 1);
  const flat = (color, scale = 1) => {
    const m = new THREE.MeshBasicMaterial({ color, side: THREE.BackSide, toneMapped: false });
    m.color.multiplyScalar(scale);
    return m;
  };
  const shell = new THREE.Mesh(box, [
    flat(0xeceae6, 0.95), // +x wall
    flat(0xeceae6, 1.05), // -x wall (the window wall)
    flat(0xf6f5f2, 1.1), // ceiling
    flat(0xd8cbb9, 0.75), // the desk and floor below
    flat(0xeceae6, 0.9), // +z
    flat(0xeceae6, 1.0), // -z
  ]);
  shell.scale.set(22, 9, 22);
  shell.position.y = 3;
  room.add(shell);
  // the window: four tall panes of soft sky, brighter than anything else
  const pane = new THREE.MeshBasicMaterial({ color: 0xf4f8ff, side: THREE.DoubleSide, toneMapped: false });
  pane.color.multiplyScalar(4.2);
  const pg = new THREE.PlaneGeometry(1, 1);
  for (let i = 0; i < 2; i++) for (let j = 0; j < 2; j++) {
    const p = new THREE.Mesh(pg, pane);
    p.rotation.y = Math.PI / 2;
    p.scale.set(2.3, 2.5, 1);
    p.position.set(-10.9, 2.6 + j * 2.7, -5.2 + i * 2.5);
    room.add(p);
  }
  // dark things across the room (a shelf, a doorway, the far end of the
  // desk): glass and lacquer need something dark to reflect, or their edges
  // vanish into a white room
  const dark = new THREE.MeshBasicMaterial({ color: 0x2a2b2e, side: THREE.DoubleSide, toneMapped: false });
  [
    [10.9, 2.2, -2.0, -Math.PI / 2, 5.5, 3.2],
    [10.9, 2.8, 4.5, -Math.PI / 2, 2.4, 5.0],
    [-3.5, 2.4, 10.9, Math.PI, 6.0, 2.6],
    [4.5, 1.6, -10.9, 0, 4.0, 2.0],
  ].forEach(([x, y, z, ry, w, h]) => {
    const f = new THREE.Mesh(pg, dark);
    f.position.set(x, y, z);
    f.rotation.y = ry;
    f.scale.set(w, h, 1);
    room.add(f);
  });
  // a little light from the ceiling, as in a real room
  const lamp = new THREE.Mesh(pg, new THREE.MeshBasicMaterial({ color: 0xffffff, side: THREE.DoubleSide, toneMapped: false }));
  lamp.material.color.multiplyScalar(1.6);
  lamp.rotation.x = Math.PI / 2;
  lamp.scale.set(6, 4, 1);
  lamp.position.set(1, 7.4, 2);
  room.add(lamp);

  const pmrem = new THREE.PMREMGenerator(renderer);
  const env = pmrem.fromScene(room, 0.03, 0.1, 60).texture;
  pmrem.dispose();
  room.traverse((o) => o.geometry && o.geometry.dispose());
  return env;
}
