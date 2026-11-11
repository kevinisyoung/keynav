// A Typeractive split keyboard behind the title. It presses the shortcut of the mode the carousel is showing
// (⌘ ⇧ Space, ⌘ ⇧ J, or a tap of Right ⌥). As each shortcut's last key goes down, a wave of letters leaves the
// keyboard; Clicking's also briefly drops label hints on the things it passes. With the sound on, it plays the
// shortcuts to the second drop of a song instead.
import * as THREE from "three";
import { GLTFLoader } from "three/addons/loaders/GLTFLoader.js";
import { DRACOLoader } from "three/addons/loaders/DRACOLoader.js";
import { RoomEnvironment } from "three/addons/environments/RoomEnvironment.js";

const host = document.getElementById("keyboard");
const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
const dark = window.matchMedia("(prefers-color-scheme: dark)");

// Where each shortcut key sits on the board: which half, which column counted from the outside edge, which row
// counted from the top, or which thumb key counted from the outside.
const placement = {
  shift: { side: "left", column: 0, row: 1 },
  command: { side: "left", thumb: 1 },
  space: { side: "right", thumb: 2 },
  j: { side: "right", column: 4, row: 1 },
  roption: { side: "right", column: 0, row: 2 },
};
// What's printed on each key, by half: rows from the top and columns from the outside edge, then the thumb
// keys from the outside in.
const printed = {
  left: { rows: [["⇥", "Q", "W", "E", "R", "T"], ["⇧", "A", "S", "D", "F", "G"], ["⌃", "Z", "X", "C", "V", "B"]], thumbs: ["⌥", "⌘", "⏎"] },
  right: { rows: [["-", "P", "O", "I", "U", "Y"], ["'", ";", "L", "K", "J", "H"], ["⌥", "/", ".", ",", "M", "N"]], thumbs: ["esc", "⌫", "space"] },
};

let renderer;
try {
  renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
} catch {
  host.remove();
}

let pressKeys = () => {};
let sharpen = () => {};
let typeKey = () => {};
let sweepIn = () => {};
let clearKeys = () => {};
let dimKeys = () => {};
let edges = null;

if (renderer) {
  // It sits blurred behind the title, so a lower pixel density costs nothing to the eye and a lot less GPU.
  renderer.setPixelRatio(Math.min(window.devicePixelRatio, 1.25));
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.toneMappingExposure = 0.82;
  host.appendChild(renderer.domElement);

  const scene = new THREE.Scene();
  scene.environment = new THREE.PMREMGenerator(renderer).fromScene(new RoomEnvironment(), 0.04).texture;

  const camera = new THREE.PerspectiveCamera(30, 1, 0.1, 100);
  // Looking down from the front, centred, so the far rows sit only a little further back.
  camera.position.set(0, 12.5, 6.2);
  camera.lookAt(0, 0, 1.3);

  // Soft, even light: shapes read through gentle shading rather than hard edges and shadows.
  const sun = new THREE.DirectionalLight(0xffffff, 0.7);
  sun.position.set(0, 12, 8);
  scene.add(sun, new THREE.HemisphereLight(0xffffff, 0xcfd0d8, 1.6));

  const board = new THREE.Group();
  scene.add(board);

  const width = 13;
  // Each part keeps its own colour, taken a little toward the page's so the board sits in the background.
  const page = new THREE.Color();
  const parts = [];
  const ink = new THREE.Color();
  let depth = 5;
  const capBlue = new THREE.Color("#5b8cff");
  const glowBlue = new THREE.Color("#2f6bff");
  const white = new THREE.Color("#fff");
  const capRed = new THREE.Color("#ff4d4d");
  const keys = [];
  // How far a key travels, in the model's own units (metres).
  const travel = 0.0032;

  function legend(text) {
    const canvas = document.createElement("canvas");
    canvas.width = 256;
    canvas.height = 256;
    const ctx = canvas.getContext("2d");
    ctx.fillStyle = "#fff";
    ctx.font = `500 ${text.length > 2 ? 72 : 112}px -apple-system, "SF Pro Text", "Helvetica Neue", sans-serif`;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(text, 128, 132);
    const texture = new THREE.CanvasTexture(canvas);
    texture.colorSpace = THREE.SRGBColorSpace;
    texture.anisotropy = 4;
    return texture;
  }

  // The model is Draco-compressed so it downloads quickly; the decoder comes from the same CDN as three.
  const draco = new DRACOLoader().setDecoderPath("https://cdn.jsdelivr.net/npm/three@0.160.0/examples/jsm/libs/draco/gltf/");
  // The model's glass-like parts would make three.js draw the whole scene twice a frame, so every part gets a
  // plain material and the glass turns solid.
  function plain(material) {
    return new THREE.MeshStandardMaterial({
      name: material.name, color: material.color, map: material.map, roughness: material.roughness,
      metalness: material.metalness,
    });
  }

  new GLTFLoader().setDRACOLoader(draco).load("typeractive.glb?v=4", gltf => {
    const model = gltf.scene;
    // Its own cameras and lights aren't used.
    model.traverse(o => { if (o.isLight || o.isCamera) o.visible = false; });
    model.traverse(o => {
      if (!o.isMesh || o.material.name === "keycap") return;
      o.material = plain(o.material);
      parts.push({ material: o.material, own: o.material.color.clone() });
    });
    model.updateMatrixWorld(true);

    // The keycaps and switches come as instanced meshes; each becomes its own mesh so it can move alone.
    // A whole switch goes down with its cap, or it would poke through the top.
    const separate = name => {
      const meshes = [];
      const instanced = [];
      model.traverse(o => { if (o.isInstancedMesh && o.material.name === name) instanced.push(o); });
      instanced.forEach(mesh => {
        const matrix = new THREE.Matrix4();
        // Straight down the board, in this mesh's own units.
        const down = new THREE.Vector3(0, 0, -1).applyMatrix3(new THREE.Matrix3().setFromMatrix4(mesh.parent.matrixWorld.clone().invert()));
        for (let i = 0; i < mesh.count; i++) {
          mesh.getMatrixAt(i, matrix);
          matrix.premultiply(mesh.matrix);
          const part = new THREE.Mesh(mesh.geometry, name === "keycap" ? plain(mesh.material) : mesh.material);
          part.applyMatrix4(matrix);
          part.userData = { rest: part.position.clone(), down };
          mesh.parent.add(part);
          meshes.push(part);
        }
        mesh.parent.remove(mesh);
      });
      return meshes;
    };
    const caps = separate("keycap");
    const switches = ["stem", "top", "bottom"].flatMap(separate);
    model.updateMatrixWorld(true);
    const centreOf = mesh => {
      mesh.geometry.computeBoundingBox();
      return mesh.geometry.boundingBox.getCenter(new THREE.Vector3()).applyMatrix4(mesh.matrixWorld);
    };
    // Measured now, in the model's own frame, before it is placed in the scene.
    const switchCentres = switches.map(centreOf);
    const capCentres = new Map(caps.map(cap => [cap, centreOf(cap)]));

    // The model lies in its x–y plane with z up; stand it on the page's floor and size it to the scene.
    const box = new THREE.Box3().setFromObject(model, true);
    const size = box.getSize(new THREE.Vector3());
    const centre = box.getCenter(new THREE.Vector3());
    const scale = width / size.x;
    depth = size.y * scale;
    const holder = new THREE.Group();
    holder.rotation.x = -Math.PI / 2;
    holder.scale.setScalar(scale);
    model.position.set(-centre.x, -centre.y, -box.min.z);
    holder.add(model);
    board.add(holder);
    board.position.z = 0.6;
    board.updateMatrixWorld(true);

    // Where each cap sits, to find the shortcut keys: thumbs are the low keys of each half, the rest form
    // columns from the outside edge in and rows from the top down.
    const info = caps.map(cap => {
      cap.geometry.computeBoundingBox();
      const c = cap.geometry.boundingBox.getCenter(new THREE.Vector3()).applyMatrix4(cap.matrixWorld);
      const local = holder.worldToLocal(c.clone());
      return { cap, x: local.x, y: local.y };
    });
    for (const side of ["left", "right"]) {
      const half = info.filter(k => (side === "left") === (k.x < 0));
      const outward = k => side === "left" ? k.x : -k.x;
      const thumbs = [...half].sort((a, b) => a.y - b.y).slice(0, 3).sort((a, b) => outward(a) - outward(b));
      thumbs.forEach((k, i) => { k.side = side; k.thumb = i; });
      const rest = half.filter(k => !thumbs.includes(k)).sort((a, b) => outward(a) - outward(b));
      for (let column = 0; column * 3 < rest.length; column++) {
        rest.slice(column * 3, column * 3 + 3).sort((a, b) => b.y - a.y)
          .forEach((k, row) => Object.assign(k, { side, column, row }));
      }
    }

    info.forEach(k => {
      const name = Object.keys(placement).find(n => Object.entries(placement[n]).every(([key, v]) => k[key] === v));
      const material = k.cap.material;
      material.emissive = glowBlue.clone();
      material.emissiveIntensity = 0;
      const text = k.thumb !== undefined ? printed[k.side].thumbs[k.thumb] : printed[k.side].rows[k.row]?.[k.column];
      // Lies on the cap's top face, in the cap's own frame.
      // The cap's geometry has its own units and may lie on its side, so the legend finds the cap's top face
      // and the board's back edge in the cap's own frame.
      const toCap = new THREE.Matrix3().setFromMatrix4(k.cap.matrixWorld.clone().invert().multiply(holder.matrixWorld));
      const up = new THREE.Vector3(0, 0, 1).applyMatrix3(toCap).normalize();
      const back = new THREE.Vector3(0, 1, 0).applyMatrix3(toCap).normalize();
      const across = new THREE.Vector3().crossVectors(back, up).normalize();
      const box = k.cap.geometry.boundingBox;
      const height = Math.abs(box.max.clone().sub(box.min).dot(up));
      // The same printed size on every key, whatever the cap's own units.
      const side = 0.46 / k.cap.getWorldScale(new THREE.Vector3()).x;
      const top = new THREE.Mesh(
        new THREE.PlaneGeometry(side, side),
        new THREE.MeshBasicMaterial({ map: legend(text || ""), transparent: true, depthWrite: false }),
      );
      top.position.copy(box.getCenter(new THREE.Vector3())).addScaledVector(up, height * 0.52);
      top.setRotationFromMatrix(new THREE.Matrix4().makeBasis(across, back, up));
      k.cap.add(top);
      // The switch straight under the cap: the nearest stem, housing top and bottom.
      const here = capCentres.get(k.cap);
      const under = ["stem", "top", "bottom"].map(name => {
        let found = null, best = Infinity;
        switchCentres.forEach((c, i) => {
          const d = Math.hypot(c.x - here.x, c.y - here.y);
          if (switches[i].material.name === name && d < best) { best = d; found = switches[i]; }
        });
        return found;
      });
      keys.push({
        name, material, legend: top.material, own: material.color.clone(), parts: [k.cap, ...under].filter(Boolean),
        text, press: 0, target: 0, lit: 0, dim: false, bump: 0, flash: 0,
      });
    });
    applyTheme();
    edges = boardEdges;
  });

  // A part's own colour taken a little toward the page's, as the eye sees it; the fog lightens it further.
  const a = {}, b = {};
  function toward(target, own) {
    own.getRGB(a, THREE.SRGBColorSpace);
    page.getRGB(b, THREE.SRGBColorSpace);
    const t = 0.3;
    return target.setRGB(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, THREE.SRGBColorSpace);
  }

  function applyTheme() {
    const isDark = dark.matches;
    page.set(isDark ? "#0e0e10" : "#fafaf9");
    ink.set(isDark ? "#b4b4be" : "#c8c8d0");
    parts.forEach(p => toward(p.material.color, p.own));
    scene.fog = new THREE.Fog(isDark ? "#0e0e10" : "#fafaf9", 10, 17);
  }
  applyTheme();
  dark.addEventListener("change", applyTheme);

  function resize() {
    const { width: w, height: h } = host.getBoundingClientRect();
    renderer.setSize(w, h, false);
    camera.aspect = w / h;
    // Fit the whole board on narrow screens.
    camera.fov = w < 640 ? 60 : 38;
    camera.updateProjectionMatrix();
  }
  new ResizeObserver(resize).observe(host);
  // Unblurred while the music plays, so a little sharper then.
  sharpen = on => { renderer.setPixelRatio(Math.min(window.devicePixelRatio, on ? 1.75 : 1.25)); resize(); };
  resize();

  let last = performance.now();
  let visible = true;
  new IntersectionObserver(([entry]) => { visible = entry.isIntersecting; }).observe(host);

  // The board's outline on the page: its front edge (bottom on screen) and back edge (top).
  function boardEdges() {
    board.updateMatrixWorld();
    const rect = host.getBoundingClientRect();
    const toPage = v => {
      const p = v.clone().applyMatrix4(board.matrixWorld).project(camera);
      return { x: rect.left + scrollX + (p.x + 1) / 2 * rect.width, y: rect.top + scrollY + (1 - p.y) / 2 * rect.height };
    };
    const front = [toPage(new THREE.Vector3(-width / 2, 0, depth / 2)), toPage(new THREE.Vector3(width / 2, 0, depth / 2))];
    const back = [toPage(new THREE.Vector3(-width / 2, 0.5, -depth / 2)), toPage(new THREE.Vector3(width / 2, 0.5, -depth / 2))];
    return {
      left: Math.min(front[0].x, back[0].x), right: Math.max(front[1].x, back[1].x),
      bottom: Math.max(front[0].y, front[1].y), top: Math.min(back[0].y, back[1].y),
    };
  }

  // Shortcut keys go down and light up; `false` lets every key back up.
  pressKeys = (names, down = true) => keys.forEach(k => {
    if (!names.includes(k.name)) return;
    k.target = down ? 1 : 0;
    if (down) { k.lit = 1; k.dim = false; }
  });
  // The key printed with a letter, or "space", taps and flashes: blue, or red for the demos' presses.
  typeKey = (letter, red = false) => {
    const k = keys.find(k => k.text?.toUpperCase() === (letter === " " ? "SPACE" : letter));
    if (k) { k.bump = 1; k.flash = 1; k.red = red; }
  };
  // The board turns in from a steeper, angled view and settles flat on the drop; `0` puts it back at once.
  let sweep = null;
  sweepIn = seconds => { sweep = seconds ? { start: performance.now(), length: seconds * 1000 } : null; };
  clearKeys = () => keys.forEach(k => { k.target = 0; k.lit = 0; });
  // The shortcut's blue fades out, so the demo's red presses stand alone.
  dimKeys = () => keys.forEach(k => { if (k.lit) k.dim = true; });

  // Full rate while keys move; otherwise the slow bob only needs 30 frames a second.
  function frame(now) {
    requestAnimationFrame(frame);
    const busy = sweep || keys.some(k => Math.abs(k.target - k.press) > 0.001 || k.bump > 0 || k.flash > 0 || (k.dim && k.lit > 0));
    if (!busy && now - last < 32) return;
    const dt = Math.min((now - last) / 1000, 0.05);
    last = now;
    keys.forEach(k => {
      k.press += (k.target - k.press) * Math.min(1, dt * (k.target ? 28 : 10));
      k.bump = Math.max(0, k.bump - dt * 7);
      k.flash = Math.max(0, k.flash - dt * 3);
      if (k.dim) k.lit = Math.max(0, k.lit - dt * 5);
      const down = Math.max(k.press, Math.sin(k.bump * Math.PI) * 0.8);
      k.parts.forEach(p => p.position.copy(p.userData.rest).addScaledVector(p.userData.down, travel * down));
      // A shortcut key stays blue once pressed, until its demo starts.
      // Shortcut keys light blue; keys the demos type flash red.
      const blue = Math.max(k.press, k.lit, k.red ? 0 : k.flash);
      const red = k.red ? k.flash : 0;
      toward(k.material.color, k.own).lerp(capBlue, blue).lerp(capRed, red);
      k.material.emissiveIntensity = 0.55 * k.press;
      k.legend.color.copy(ink).lerp(white, Math.max(blue, red));
    });
    board.position.y = reduce ? 0 : Math.sin(now / 2200) * 0.06;
    const away = sweep ? 1 - Math.min(1, (now - sweep.start) / sweep.length) : 0;
    const ease = away * away * away;
    board.rotation.set(0.6 * ease, -0.5 * ease, 0);
    if (sweep && !away) sweep = null;
    if (visible) renderer.render(scene, camera);
  }
  requestAnimationFrame(frame);
}

// Plays a mode's shortcut: its keys go down one at a time, are held, then let go. A tap goes straight back up.
// The last key sends the wave.
let pending = [];
let music = false;
function play(shortcut) {
  if (music) return;
  pending.forEach(clearTimeout);
  pending = [];
  clearKeys();
  // Timed from when the carousel asked, which may be before this module finished loading.
  const since = performance.now() - shortcut.at;
  const later = (fn, ms) => pending.push(setTimeout(fn, Math.max(0, ms - since)));
  if (reduce) { pressKeys(shortcut.keys); return; }
  shortcut.keys.forEach((name, i) => later(() => {
    pressKeys([name]);
    if (shortcut.ripple && i === shortcut.keys.length - 1 && edges) ripple(edges(), shortcut.labels);
  }, 250 + i * 350));
  const up = 250 + (shortcut.keys.length - 1) * 350 + (shortcut.tap ? 180 : 900);
  later(() => pressKeys(shortcut.keys, false), up);
}
document.addEventListener("shortcut", e => play(e.detail));
// The carousel may have asked before this module loaded.
if (window.keynavShortcut) play(window.keynavShortcut);

// MARK: - The drop

// The sound button plays a song from just before its second drop. The build-up drums on the keys, and from the
// drop each bar slams the next mode's shortcut and sends its wave, while the carousel waits.
const sound = document.querySelector(".sound");
const mute = document.querySelector(".mute");
const shortcuts = [["command", "shift", "space"], ["command", "shift", "j"], ["roption"]];
const beat = 60 / 129.2;
const drop = 3.715; // seconds into the clip: two bars of build-up
// From the drop, the headline names the mode playing, and a bar under it fills through the mode's two bars.
const phrases = ["Shortcuts everywhere", "Scroll anywhere", "Move the mouse"];
const title = document.querySelector("header h1");
const cine = title.querySelector(".cine");
const bars = [...document.querySelectorAll(".cine-bar span")];
const combos = [...document.querySelectorAll(".slide .combo")];
function name(mode) {
  title.classList.add("naming");
  const showing = cine.classList.contains("on");
  cine.classList.remove("on");
  // The old name fades out before the new one fades in.
  setTimeout(() => { cine.classList.remove("quote"); cine.textContent = phrases[mode]; cine.classList.add("on"); }, showing ? 250 : 0);
  bars.forEach((bar, i) => {
    bar.classList.toggle("done", i < mode);
    bar.classList.remove("active");
    void bar.offsetWidth;
    bar.classList.toggle("active", i === mode);
    bar.style.setProperty("--t", `${8 * beat}s`);
  });
}
// The voice's line in the build-up.
function say() {
  cine.innerHTML = "<span class=\"by\">Your Homerow:</span>“Keep your hands where I can see them”";
  cine.classList.add("quote", "on");
  title.classList.add("naming");
}
function unname() {
  title.classList.remove("naming");
  cine.classList.remove("on", "quote");
  bars.forEach(bar => bar.classList.remove("done", "active"));
}

let audio, cues, playing;
// After the song, once it has faded out, a forest recording (BigSoundBank's "Forest and Stream #1" by Pierre Sibanarco, CC0) loops
// quietly until the sound is turned off. Web Audio loops it without a gap.
let context, forest, forestGain, forestSource;

function score() {
  const list = [];
  // The bar before the drop rolls along the home row in sixteenths, while the board sweeps in.
  // The quote appears as the voice starts, 0.3 s in.
  list.push({ t: 0.3, run: say });
  [..."ASDFJKL;;LKJFDSA"].forEach((letter, i) => list.push({ t: drop - 4 * beat + i * beat / 4, run: () => typeKey(letter) }));

  // From the drop, each mode gets two bars: its shortcut goes down once and sends its wave, and its name lights
  // up. Click's wave labels what's still on the page as it passes.
  shortcuts.forEach((keys, mode) => {
    const t = drop + mode * 8 * beat;
    // Its shortcut hint appears with it, the hint's keys going down with the board's.
    const combo = combos[mode];
    // Scroll and Move come in on the song's dings, a little ahead of their beats.
    list.push({ t: t - [0, 0.314, 0.15][mode], run: () => {
      clearKeys(); pressKeys(keys);
      name(mode);
      window.keynavCarousel?.show(mode);
      combos.forEach(c => c.classList.toggle("shown", c === combo));
      combo.querySelectorAll("kbd").forEach(k => k.classList.add("down"));
      if (edges) ripple(edges(), mode === 0 ? "visible" : false);
    } });
    list.push({ t: t + 1.5 * beat, run: () => {
      pressKeys(keys, false);
      combo.querySelectorAll("kbd").forEach(k => k.classList.remove("down"));
    } });
  });
  // Each mode then shows what it does, on the beat.
  const at = (t, run) => list.push({ t, run });
  // Just before each demo's first red press, the shortcut's blue fades away.
  [3.5, 9.5, 17].forEach(b => at(drop + b * beat, dimKeys));
  // Click: the board types Download's label, and Download is pressed.
  const download = document.querySelector(".download");
  // They land a hair after the beat, which is where it sounds.
  const late = 0.04;
  at(drop + 4 * beat + late, () => { typeKey("D", true); labelOf(download)?.classList.add("typed"); });
  at(drop + 4.5 * beat + late, () => { typeKey("F", true); download.classList.add("pressed"); });
  at(drop + 5.5 * beat + late, () => download.classList.remove("pressed"));
  // Scroll: a small window opens over the board, KeyNav outlines its list, and J and K scroll it down and up.
  at(drop + 8.5 * beat, () => windowed(true));
  at(drop + 9 * beat, () => inbox.classList.add("outlined"));
  [["J", 2], ["J", 4], ["K", 2], ["J", 5], ["K", 3], ["K", 1]].forEach(([key, rows], i) =>
    at(drop + (10 + i) * beat, () => { typeKey(key, true); inbox.firstChild.style.transform = `translateY(${-rows * 28}px)`; }));
  at(drop + 16 * beat, () => inbox.classList.remove("outlined"));
  // Move: a pointer in the same window steps with I (up), J (left), K (down) and L (right), and Space clicks
  // the row under it.
  at(drop + 17 * beat, () => cursor("show"));
  [["J", -1, 0], ["J", -1, 0], ["I", 0, -1], ["I", 0, -1], ["J", -1, 0], ["K", 0, 1]].forEach(([key, x, y], i) =>
    at(drop + (17.5 + i * 0.5) * beat, () => { typeKey(key, true); cursor("move", x, y); }));
  at(drop + 21 * beat, () => { typeKey(" ", true); cursor("click"); });
  at(drop + 23 * beat, () => { cursor("hide"); windowed(false); });
  // Once all three have played, the page settles back while the song fades out.
  at(drop + 24 * beat, settle);
  return list.sort((a, b) => a.t - b.t);
}

function follow() {
  if (!playing) return;
  while (cues.length && cues[0].t <= audio.currentTime) cues.shift().run();
  requestAnimationFrame(follow);
}

// The song is over: the forest loops, the button offers to replay, and a mute button appears beside it.
// After forty seconds it fades out on its own.
let quiet;
function intoWoods() {
  if (!woods(true)) return false;
  playing = false;
  played();
  mute.hidden = false;
  clearTimeout(quiet);
  quiet = setTimeout(hush, 40000);
  return true;
}

function hush() {
  clearTimeout(quiet);
  woods(false);
  mute.hidden = true;
}

function played() {
  sound.setAttribute("aria-pressed", "false");
  sound.setAttribute("aria-label", "Play the keyboard to music again");
  sound.classList.add("played");
}

mute?.addEventListener("click", hush);

function stop() {
  playing = false;
  audio?.pause();
  hush();
  played();
  if (music) settle();
}

// The forest creeps in over eight seconds to a quiet level, so its stream doesn't rush in like a whoosh, or fades
// out over one and a half. True when it started.
function woods(on) {
  if (!context || !forest) return false;
  const now = context.currentTime;
  forestGain.gain.cancelScheduledValues(now);
  forestGain.gain.setValueAtTime(forestGain.gain.value, now);
  if (on) {
    forestSource?.stop();
    forestSource = Object.assign(context.createBufferSource(), { buffer: forest, loop: true });
    forestSource.connect(forestGain);
    forestSource.start();
    forestGain.gain.setValueAtTime(0, now);
    forestGain.gain.linearRampToValueAtTime(0.02, now + 2);
    forestGain.gain.linearRampToValueAtTime(0.35, now + 8);
    return true;
  } else if (forestSource) {
    forestGain.gain.linearRampToValueAtTime(0, now + 1.5);
    forestSource.stop(now + 1.6);
    forestSource = null;
  }
  return false;
}

// The window the scroll and move demos happen in: a short list of mail over the middle of the keyboard.
const subjects = ["Design review", "Lunch on Friday?", "Q4 roadmap", "Flights to Tokyo", "Invoice 2041", "Team offsite",
  "Photos from Sunday", "Re: launch plan", "Weekly sync", "New comment", "Dentist reminder", "Weekend plans"];
let pane, inbox;
function windowed(on) {
  if (on && edges) {
    const e = edges();
    if (!pane) {
      pane = Object.assign(document.createElement("div"), {
        className: "demo-window",
        innerHTML: `<div class="lights"><i></i><i></i><i></i></div><div class="list"><div>${subjects.map(s => `<p>${s}</p>`).join("")}</div></div>`,
      });
      inbox = pane.querySelector(".list");
    }
    inbox.firstChild.style.transform = "";
    pane.querySelectorAll("p.picked").forEach(p => p.classList.remove("picked"));
    layer.appendChild(pane);
    Object.assign(pane.style, { left: `${(e.left + e.right) / 2}px`, top: `${(e.top + e.bottom) / 2}px` });
    requestAnimationFrame(() => pane.classList.add("on"));
  } else {
    pane?.classList.remove("on");
    inbox?.classList.remove("outlined");
  }
}

// The move demo's pointer, which steps across the window and clicks a row.
let arrow, spot;
function cursor(what, dx = 0, dy = 0) {
  if (what === "show" && pane) {
    const r = inbox.getBoundingClientRect();
    // Near the lower right, so its steps left and up stay inside the list.
    spot = { x: r.left + scrollX + 200, y: r.top + scrollY + 100 };
    arrow ??= Object.assign(document.createElement("div"), {
      className: "move-pointer",
      innerHTML: '<svg viewBox="0 0 16 22"><path d="M1 1v16.5l4.2-4 2.9 6.6 2.6-1.1-2.8-6.5H14z" fill="#000" stroke="#fff" stroke-width="1.4" stroke-linejoin="round"/></svg>',
    });
    layer.appendChild(arrow);
  }
  if (!arrow) return;
  if (what === "move") { spot.x += dx * 48; spot.y += dy * 28; }
  arrow.style.transform = `translate(${spot.x}px, ${spot.y}px)`;
  arrow.classList.toggle("on", what !== "hide");
  if (what === "click") {
    arrow.classList.remove("clicking"); void arrow.offsetWidth; arrow.classList.add("clicking");
    // The row under the pointer's tip is picked.
    const x = spot.x - scrollX + 2, y = spot.y - scrollY + 2;
    [...inbox.querySelectorAll("p")].find(p => {
      const r = p.getBoundingClientRect();
      return x >= r.left && x <= r.right && y >= r.top && y <= r.bottom;
    })?.classList.add("picked");
  }
}

// The label the wave left on an element, if it's still up.
function labelOf(el) {
  return [...document.querySelectorAll(".hint")].find(h => h.target === el);
}

// The page as it was: everything back, the keyboard behind the title, the carousel playing again.
function settle() {
  windowed(false);
  cursor("hide");
  music = false;
  document.body.classList.remove("music");
  sharpen(false);
  // Its size frees up once the header has finished shrinking back around it.
  setTimeout(() => { if (!music) host.style.height = host.style.bottom = ""; }, 900);
  unname();
  combos.forEach(c => c.classList.remove("shown"));
  document.querySelectorAll(".combo kbd.down").forEach(k => k.classList.remove("down"));
  sweepIn(0);
  clearKeys();
  window.keynavCarousel?.resume();
}

sound?.addEventListener("click", () => {
  if (playing) return stop();
  window.keynavHit?.("play");
  // The clip is mixed quiet in the file itself, since iOS ignores a page setting its volume.
  audio ??= new Audio("drop.m4a?v=13");
  audio.currentTime = 0;
  hush();
  // The forest begins once the song has faded out; without the forest, it's the end.
  audio.onended = () => { if (!intoWoods()) stop(); };
  if (!context) {
    context = new (window.AudioContext || window.webkitAudioContext)();
    forestGain = context.createGain();
    forestGain.gain.value = 0;
    forestGain.connect(context.destination);
    fetch("forest.m4a?v=1").then(r => r.arrayBuffer()).then(b => context.decodeAudioData(b)).then(b => { forest = b; }, () => {});
  }
  context.resume();
  cues = score();
  playing = true;
  music = true;
  pending.forEach(clearTimeout);
  // Labels the page's own waves left go, so only the music's appear.
  document.querySelectorAll(".hint").forEach(h => h.remove());
  clearKeys();
  window.keynavCarousel?.pause();
  sound.setAttribute("aria-pressed", "true");
  // The keyboard slides down below the download, which moves up into the space the line under the title leaves,
  // and the header grows to make room for it.
  if (edges) {
    const board = edges();
    // Its size stays put while the header grows around it.
    host.style.height = `${host.getBoundingClientRect().height}px`;
    host.style.bottom = "auto";
    const lede = document.querySelector("header .lede");
    // The progress bar takes 34 points under the title.
    const below = document.querySelector(".requirement").getBoundingClientRect().bottom + scrollY
      - lede.offsetHeight - parseFloat(getComputedStyle(lede).marginBottom) + 34;
    host.style.setProperty("--slide", `${below + 28 - board.top}px`);
    host.parentElement.style.setProperty("--room", `${board.bottom - board.top + 28}px`);
  }
  document.body.classList.add("music");
  sharpen(true);
  audio.play().then(() => { sweepIn(drop); follow(); }, stop);
});

// MARK: - The ripple

// One wave of letters leaves the keyboard: down from its front edge and up from its back edge. It is drawn on
// a fixed canvas over the page and fades as it travels.
const layer = document.getElementById("ripples");
const canvas = document.getElementById("ascii");
const ctx = canvas.getContext("2d");
const speed = 340; // px per second
const crest = 22; // half-thickness of the wave, px
const cell = 14;
const alphabet = "ASDFGHJKLQWERTYUIOPZXCVBNM";
// Only things a person could click get a hint; headings and the shortcuts panel do not.
const hintTargets = ".brand, .nav-link, .download, .tile, .pill, .thread, .send, .tool, .pills button, footer a";
const letters = "asdfghjkl";
const waves = [];
let drawing = false;

function sizeCanvas() {
  const ratio = Math.min(window.devicePixelRatio, 2);
  canvas.width = innerWidth * ratio;
  canvas.height = innerHeight * ratio;
  ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
}
sizeCanvas();
addEventListener("resize", sizeCanvas);

function hash(x, y, t) {
  const n = Math.sin(x * 127.1 + y * 311.7 + t * 74.7) * 43758.5453;
  return n - Math.floor(n);
}

// One front of the wave. `direction` is 1 travelling down from the front edge, -1 travelling up from the back.
// The middle leads and the sides trail behind in an arc, with a gentle undulation along it.
function band(ctx, wave, distance, direction, age, isDark) {
  const origin = direction > 0 ? wave.bottom : wave.top;
  const far = direction > 0 ? wave.farDown : wave.farUp;
  if (distance > far) return;
  // Holds its strength most of the way, then fades out at the end of the page.
  const strength = Math.max(0, 1 - Math.pow(distance / far, 3));
  const centre = (wave.left + wave.right) / 2 - scrollX;
  // The arc widens as it travels, so its shape (depth to width) stays the same all the way down.
  const half = (wave.right - wave.left) / 2 + distance * 0.8;
  const radius = half * 1.6;
  const reach = origin + direction * distance - scrollY;
  const edge = origin - scrollY;
  const tick = Math.floor(age * 5);
  const columns = Math.ceil(innerWidth / cell);
  for (let gx = 0; gx < columns; gx++) {
    const cx = gx * cell + cell / 2;
    const across = (cx - centre) / half;
    const dx = Math.min(Math.abs(cx - centre), radius);
    const lag = radius - Math.sqrt(radius * radius - dx * dx);
    const front = reach - direction * lag;
    const sideFade = Math.exp(-(Math.max(0, Math.abs(across) - 1) ** 2) * 3);
    const y0 = Math.max(0, Math.floor((front - crest) / cell)), y1 = Math.min(Math.ceil(innerHeight / cell), Math.ceil((front + crest) / cell));
    for (let gy = y0; gy < y1; gy++) {
      const cy = gy * cell + cell / 2;
      // Nothing over the keyboard itself: the wave appears only once it has left it.
      if (direction > 0 ? cy < edge : cy > edge) continue;
      const u = (cy - front) / crest;
      const v = Math.exp(-u * u * 2.4) * sideFade * strength * (0.65 + 0.35 * hash(gx, gy, 0));
      if (v < 0.12) continue;
      ctx.fillStyle = isDark ? `rgba(130, 168, 255, ${Math.min(0.6, v * 0.6)})` : `rgba(37, 92, 240, ${Math.min(0.5, v * 0.55)})`;
      ctx.fillText(alphabet[Math.floor(hash(gx, gy, tick) * alphabet.length)], cx, cy);
    }
  }
}

function draw(now) {
  ctx.clearRect(0, 0, innerWidth, innerHeight);
  const isDark = dark.matches;
  ctx.font = `700 ${cell - 3}px ui-monospace, "SF Mono", Menlo, monospace`;
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  for (let w = waves.length - 1; w >= 0; w--) {
    const wave = waves[w];
    const age = (now - wave.start) / 1000;
    const distance = age * speed;
    if (distance > Math.max(wave.farDown, wave.farUp)) { waves.splice(w, 1); continue; }
    band(ctx, wave, distance, 1, age, isDark);
    band(ctx, wave, distance, -1, age, isDark);
  }
  if (waves.length) {
    requestAnimationFrame(draw);
  } else {
    drawing = false;
    ctx.clearRect(0, 0, innerWidth, innerHeight);
  }
}

function ripple(edges, labels) {
  const page = document.documentElement;
  layer.style.height = `${page.scrollHeight}px`;
  // All the way to the bottom of the page, and up to the top.
  const farDown = page.scrollHeight - edges.bottom;
  const farUp = edges.top;
  waves.push({ ...edges, farDown, farUp, start: performance.now() });
  if (!drawing) { drawing = true; requestAnimationFrame(draw); }
  // Only Clicking's wave labels things; the others are just the wave. With the music on, only what's still
  // showing is labelled, and the demos stay still.
  if (!labels) return;
  if (labels === "visible") {
    const codes = shuffledCodes();
    document.querySelectorAll(".brand, .nav-link, .download, .sound").forEach(el => {
      const rect = el.getBoundingClientRect();
      const y = rect.top + scrollY + rect.height;
      const distance = y > edges.bottom ? y - edges.bottom : y < edges.top ? edges.top - y : null;
      // Download's label is the one the demo types.
      if (distance !== null) setTimeout(() => showHint(el, el.matches(".download") ? ["DF"] : codes), distance / speed * 1000);
    });
    return;
  }

  // Demo windows show their own labels as the wave reaches each control, then type and click once it has passed.
  const wave = window.keynavWave ? window.keynavWave() : 0;
  const demoControls = new Set();
  (window.keynavDemos || []).forEach(demo => {
    demo.items.forEach(item => demoControls.add(item.el));
    if (!demo.active()) return;
    let last = -1;
    demo.items.forEach(item => {
      const r = item.el.getBoundingClientRect();
      if (!r.width) return;
      const y = r.top + scrollY + r.height;
      const distance = y > edges.bottom ? y - edges.bottom : y < edges.top ? edges.top - y : null;
      if (distance === null) return;
      last = Math.max(last, distance);
      setTimeout(() => demo.reveal(item, wave), distance / speed * 1000);
    });
    if (last >= 0) setTimeout(() => demo.run(wave), last / speed * 1000 + 300);
  });

  // Everything else clickable gets a passing hint as the wave reaches it, anywhere on the page.
  const codes = shuffledCodes();
  document.querySelectorAll(hintTargets).forEach(el => {
    if (demoControls.has(el)) return;
    const rect = el.getBoundingClientRect();
    if (rect.width === 0) return;
    const y = rect.top + scrollY + rect.height;
    const distance = y > edges.bottom ? y - edges.bottom : y < edges.top ? edges.top - y : null;
    if (distance === null) return;
    // A wave already on its way when the music starts leaves no labels behind it.
    setTimeout(() => { if (!music) showHint(el, codes); }, distance / speed * 1000);
  });
}

// Every two-letter code from the home row, in random order, so no two hints in a wave match.
function shuffledCodes() {
  const all = [];
  for (const a of letters) for (const b of letters) all.push((a + b).toUpperCase());
  for (let i = all.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [all[i], all[j]] = [all[j], all[i]];
  }
  return all;
}

function showHint(el, codes) {
  const rect = el.getBoundingClientRect();
  if (rect.width === 0) return;
  // Controls on a slide that isn't showing get nothing.
  const slide = el.closest(".slide");
  if (slide && !slide.classList.contains("current")) return;
  // A hint already up keeps its code and just starts its time over.
  const up = [...document.querySelectorAll(".hint")].find(h => h.target === el);
  if (up) {
    up.classList.remove("again");
    void up.offsetWidth;
    up.classList.add("again");
    return;
  }
  const hint = document.createElement("span");
  hint.className = "hint";
  hint.textContent = codes.pop() || "AA";
  // On a slide the hint lives inside it, so it moves with the slide and is clipped with it.
  const host = slide || layer;
  const box = slide ? slide.getBoundingClientRect() : { left: -scrollX, top: -scrollY };
  Object.assign(hint.style, { left: `${rect.left - box.left + rect.width / 2}px`, top: `${rect.bottom - box.top - 4}px` });
  hint.target = el;
  host.appendChild(hint);
  hint.addEventListener("animationend", () => hint.remove());
}

// When the carousel moves, hints on the slide it leaves go with it.
document.addEventListener("slidechange", () => {
  document.querySelectorAll(".slide .hint").forEach(h => h.remove());
});
