import * as THREE from "three";
import { GLTFLoader } from "three/addons/loaders/GLTFLoader.js";
import { FBXLoader } from "three/addons/loaders/FBXLoader.js";
import { VRMLoaderPlugin, VRMUtils } from "@pixiv/three-vrm";

const viewer = document.querySelector(".vrm-viewer");
const stage = viewer.querySelector("[data-vrm-stage]");
const loaderEl = viewer.querySelector("[data-vrm-loader]");
const nameEl = viewer.querySelector("[data-vrm-name]");
const statusEl = viewer.querySelector("[data-vrm-status]");
const closeBtn = viewer.querySelector("[data-vrm-close]");
const buttons = document.querySelectorAll(".say-hi-button");

const WAVE_URLS = {
  female: "../assets/vrm/Waving.fbx",
  male: "../assets/vrm/hello-male.fbx",
};
const IDLE_URLS = {
  female: "../assets/vrm/Idle-1.fbx",
  male: "../assets/vrm/idle-male-1.fbx",
};

const WAVE_DURATION_MS = 2000;

const vrmCache = new Map();
let renderer, scene, camera, clock;
let currentVrm = null;
let currentMixer = null;
let currentAudio = null;
let waveTimeout = null;
let booted = false;

// lip-sync state
let audioCtx = null;
let analyser = null;
let analyserData = null;
const audioSourceCache = new WeakMap();
let mouthValue = 0;

const setStatus = (text) => {
  if (statusEl) statusEl.textContent = text;
};

const open = () => {
  viewer.dataset.state = "open";
  viewer.setAttribute("aria-hidden", "false");
};

const close = () => {
  viewer.dataset.state = "closed";
  viewer.setAttribute("aria-hidden", "true");
  if (currentAudio) {
    currentAudio.pause();
    currentAudio.currentTime = 0;
  }
};

closeBtn.addEventListener("click", close);

const boot = () => {
  if (booted) return;
  booted = true;

  renderer = new THREE.WebGLRenderer({ alpha: true, antialias: true });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  const rect = stage.getBoundingClientRect();
  renderer.setSize(rect.width, rect.height);
  stage.appendChild(renderer.domElement);

  scene = new THREE.Scene();
  camera = new THREE.PerspectiveCamera(28, rect.width / rect.height, 0.1, 20);

  const key = new THREE.DirectionalLight(0xffffff, 1.4);
  key.position.set(1, 2, 1.5);
  scene.add(key);
  const fill = new THREE.DirectionalLight(0xffd9ec, 0.6);
  fill.position.set(-1.2, 1.4, 1);
  scene.add(fill);
  const rim = new THREE.DirectionalLight(0xb9d2ff, 0.45);
  rim.position.set(-0.5, 1.5, -1.5);
  scene.add(rim);
  scene.add(new THREE.AmbientLight(0xffffff, 0.55));

  clock = new THREE.Clock();

  const onResize = () => {
    if (!renderer || viewer.dataset.state !== "open") return;
    const r = stage.getBoundingClientRect();
    renderer.setSize(r.width, r.height);
    camera.aspect = r.width / r.height;
    camera.updateProjectionMatrix();
  };
  window.addEventListener("resize", onResize);

  const animate = () => {
    requestAnimationFrame(animate);
    const delta = clock.getDelta();
    if (currentMixer) currentMixer.update(delta);
    if (currentVrm) {
      currentVrm.update(delta);

      // lip-sync: amplitude → mouth open
      const expressionManager = currentVrm.expressionManager;
      if (expressionManager) {
        let target = 0;
        if (analyser && analyserData && currentAudio && !currentAudio.paused) {
          analyser.getByteFrequencyData(analyserData);
          const bins = analyserData.length;
          const speechEnd = Math.max(2, Math.floor(bins * 0.2));
          let sum = 0;
          for (let i = 1; i < speechEnd; i++) sum += analyserData[i];
          const avg = sum / (speechEnd - 1) / 255;
          target = Math.min(1, Math.max(0, (avg - 0.04) * 2.4));
        }
        mouthValue += (target - mouthValue) * 0.5;
        try {
          expressionManager.setValue("aa", mouthValue);
        } catch {}
        try {
          expressionManager.setValue("a", mouthValue);
        } catch {}
        expressionManager.update();
      }
    }
    renderer.render(scene, camera);
  };
  animate();
};

// Mixamo bone name -> VRM humanoid bone name
const MIXAMO_TO_VRM = {
  mixamorigHips: "hips",
  mixamorigSpine: "spine",
  mixamorigSpine1: "chest",
  mixamorigSpine2: "upperChest",
  mixamorigNeck: "neck",
  mixamorigHead: "head",
  mixamorigLeftShoulder: "leftShoulder",
  mixamorigLeftArm: "leftUpperArm",
  mixamorigLeftForeArm: "leftLowerArm",
  mixamorigLeftHand: "leftHand",
  mixamorigRightShoulder: "rightShoulder",
  mixamorigRightArm: "rightUpperArm",
  mixamorigRightForeArm: "rightLowerArm",
  mixamorigRightHand: "rightHand",
  mixamorigLeftUpLeg: "leftUpperLeg",
  mixamorigLeftLeg: "leftLowerLeg",
  mixamorigLeftFoot: "leftFoot",
  mixamorigLeftToeBase: "leftToes",
  mixamorigRightUpLeg: "rightUpperLeg",
  mixamorigRightLeg: "rightLowerLeg",
  mixamorigRightFoot: "rightFoot",
  mixamorigRightToeBase: "rightToes",
};

// Retarget a Mixamo FBX clip to a target VRM
// Adapted from the canonical three-vrm Mixamo example
const loadMixamoAnimation = async (url, vrm) => {
  const fbx = await new FBXLoader().loadAsync(url);
  const clip = THREE.AnimationClip.findByName(fbx.animations, "mixamo.com");
  if (!clip) throw new Error("no mixamo clip in fbx");

  const tracks = [];
  const restRotInv = new THREE.Quaternion();
  const parentRestWorldRot = new THREE.Quaternion();
  const _q = new THREE.Quaternion();
  const _v = new THREE.Vector3();

  // mixamo uses centimeters, vrm uses meters → scale hips position
  const motionHipsHeight =
    fbx.getObjectByName("mixamorigHips").position.y || 100;
  const vrmHipsBone = vrm.humanoid.getNormalizedBoneNode("hips");
  const vrmHipsY = vrmHipsBone.getWorldPosition(new THREE.Vector3()).y;
  const vrmHipsHeight = Math.abs(vrmHipsY);
  const hipsPositionScale = vrmHipsHeight / motionHipsHeight;

  clip.tracks.forEach((track) => {
    const trackSplit = track.name.split(".");
    const mixamoRigName = trackSplit[0];
    const vrmBoneName = MIXAMO_TO_VRM[mixamoRigName];
    const vrmNodeName =
      vrm.humanoid?.getNormalizedBoneNode(vrmBoneName)?.name;
    const mixamoRigNode = fbx.getObjectByName(mixamoRigName);
    if (!vrmNodeName || !mixamoRigNode) return;

    const propertyName = trackSplit[1];

    // store rotations of rest pose
    mixamoRigNode.getWorldQuaternion(restRotInv).invert();
    mixamoRigNode.parent.getWorldQuaternion(parentRestWorldRot);

    if (track instanceof THREE.QuaternionKeyframeTrack) {
      // retarget rotation
      for (let i = 0; i < track.values.length; i += 4) {
        const flatQuat = track.values.slice(i, i + 4);
        _q.fromArray(flatQuat);
        // parent rest world rotation * trackQuat * boneRest^-1
        _q.premultiply(parentRestWorldRot).multiply(restRotInv);
        _q.toArray(flatQuat);
        flatQuat.forEach((v, idx) => (track.values[i + idx] = v));
      }
      tracks.push(
        new THREE.QuaternionKeyframeTrack(
          `${vrmNodeName}.${propertyName}`,
          track.times,
          track.values.map((v, i) =>
            vrm.meta?.metaVersion === "0" && i % 2 === 0 ? -v : v,
          ),
        ),
      );
    } else if (track instanceof THREE.VectorKeyframeTrack) {
      // retarget position (only hips translates)
      const value = track.values.map(
        (v, i) =>
          (vrm.meta?.metaVersion === "0" && i % 3 !== 1 ? -v : v) *
          hipsPositionScale,
      );
      tracks.push(
        new THREE.VectorKeyframeTrack(
          `${vrmNodeName}.${propertyName}`,
          track.times,
          value,
        ),
      );
    }
  });

  return new THREE.AnimationClip("Wave", clip.duration, tracks);
};

const frameCamera = (vrm) => {
  const box = new THREE.Box3().setFromObject(vrm.scene);
  const size = new THREE.Vector3();
  box.getSize(size);

  const headBone = vrm.humanoid?.getNormalizedBoneNode("head");
  let headWorld = new THREE.Vector3();
  if (headBone) headBone.getWorldPosition(headWorld);
  else headWorld.set(0, box.max.y - size.y * 0.1, 0);

  const dist = Math.max(size.y * 1.2, 1.8);
  camera.position.set(0.05, headWorld.y - size.y * 0.05, dist);
  camera.lookAt(0, headWorld.y - size.y * 0.18, 0);
};

const replaceVrm = (vrm, waveClip, idleClip) => {
  if (waveTimeout) {
    clearTimeout(waveTimeout);
    waveTimeout = null;
  }
  if (currentMixer) {
    currentMixer.stopAllAction();
    currentMixer = null;
  }
  if (currentVrm) scene.remove(currentVrm.scene);

  currentVrm = vrm;
  scene.add(vrm.scene);

  const box = new THREE.Box3().setFromObject(vrm.scene);
  vrm.scene.position.y -= box.min.y;

  currentMixer = new THREE.AnimationMixer(vrm.scene);

  let idleAction = null;
  if (idleClip) {
    idleAction = currentMixer.clipAction(idleClip);
    idleAction.setLoop(THREE.LoopRepeat);
  }

  if (waveClip) {
    const waveAction = currentMixer.clipAction(waveClip);
    waveAction.setLoop(THREE.LoopRepeat);
    waveAction.play();

    waveTimeout = setTimeout(() => {
      if (idleAction) {
        idleAction.reset();
        idleAction.play();
        waveAction.crossFadeTo(idleAction, 0.5, false);
      } else {
        waveAction.fadeOut(0.4);
      }
      waveTimeout = null;
    }, WAVE_DURATION_MS);
  } else if (idleAction) {
    idleAction.play();
  }

  frameCamera(vrm);
};

const loadCharacter = async (vrmUrl, isMale) => {
  setStatus("Loading model…");
  loaderEl.style.display = "grid";

  let vrm;
  if (vrmCache.has(vrmUrl)) {
    vrm = vrmCache.get(vrmUrl);
  } else {
    const loader = new GLTFLoader();
    loader.register((parser) => new VRMLoaderPlugin(parser));
    vrm = await new Promise((resolve, reject) => {
      loader.load(
        vrmUrl,
        (gltf) => {
          const v = gltf.userData.vrm;
          if (!v) reject(new Error("No VRM in file"));
          else resolve(v);
        },
        (progress) => {
          if (progress.lengthComputable) {
            const pct = Math.round((progress.loaded / progress.total) * 100);
            setStatus(`Loading model… ${pct}%`);
          }
        },
        (err) => reject(err),
      );
    });
    if (vrm.meta?.metaVersion === "0") VRMUtils.rotateVRM0(vrm);
    vrmCache.set(vrmUrl, vrm);
  }
  window.__vrm = vrm;
  window.__lipsync = () => {
    let avg = 0;
    let peak = 0;
    if (analyser && analyserData) {
      analyser.getByteFrequencyData(analyserData);
      const bins = analyserData.length;
      const speechEnd = Math.floor(bins * 0.18);
      let sum = 0;
      for (let i = 1; i < speechEnd; i++) {
        sum += analyserData[i];
        if (analyserData[i] > peak) peak = analyserData[i];
      }
      avg = sum / (speechEnd - 1) / 255;
    }
    return {
      analyser: !!analyser,
      ctxState: audioCtx?.state,
      audioPaused: currentAudio?.paused,
      audioVolume: currentAudio?.volume,
      mouth: mouthValue,
      avg,
      peak,
      expressions: vrm.expressionManager?.expressions?.map((e) => ({
        n: e.expressionName,
        w: e.weight,
      })),
    };
  };

  setStatus("Warming up…");
  const waveUrl = isMale ? WAVE_URLS.male : WAVE_URLS.female;
  const idleUrl = isMale ? IDLE_URLS.male : IDLE_URLS.female;

  let waveClip = null;
  let idleClip = null;
  try {
    [waveClip, idleClip] = await Promise.all([
      loadMixamoAnimation(waveUrl, vrm),
      loadMixamoAnimation(idleUrl, vrm).catch(() => null),
    ]);
  } catch (e) {
    console.warn("animation load failed", e);
  }

  replaceVrm(vrm, waveClip, idleClip);
  loaderEl.style.display = "none";
};

const ensureAudioGraph = () => {
  if (audioCtx) return;
  const Ctx = window.AudioContext || window.webkitAudioContext;
  if (!Ctx) return;
  audioCtx = new Ctx();
  analyser = audioCtx.createAnalyser();
  analyser.fftSize = 1024;
  analyser.smoothingTimeConstant = 0.55;
  analyserData = new Uint8Array(analyser.frequencyBinCount);
  analyser.connect(audioCtx.destination);
};

const playAudio = (src) => {
  if (currentAudio) {
    currentAudio.pause();
    currentAudio.currentTime = 0;
  }
  ensureAudioGraph();
  const audio = new Audio(src);
  currentAudio = audio;

  // route the audio element through the analyser so we can read amplitude
  if (audioCtx && analyser) {
    if (audioCtx.state === "suspended") audioCtx.resume();
    let source = audioSourceCache.get(audio);
    if (!source) {
      try {
        source = audioCtx.createMediaElementSource(audio);
        source.connect(analyser);
        audioSourceCache.set(audio, source);
      } catch (e) {
        // already connected by another graph — fall back to plain playback
      }
    }
  }

  audio.addEventListener("ended", () => {
    mouthValue = 0;
  });
  audio.play().catch(() => {});
};

buttons.forEach((button) => {
  button.addEventListener("click", async () => {
    const vrmUrl = button.dataset.vrm;
    const voiceUrl = button.dataset.voice;
    const character = button.dataset.character || "Sensei";
    const isMale = button.dataset.male === "true";

    nameEl.textContent = character;
    open();
    boot();

    buttons.forEach((b) => b.classList.remove("is-active"));
    button.classList.add("is-active");

    try {
      await loadCharacter(vrmUrl, isMale);
      setStatus(`${character} is waving at you ✿`);
      if (voiceUrl) playAudio(voiceUrl);
    } catch (e) {
      console.error("VRM load failed", e);
      setStatus("Couldn't load — try again?");
      loaderEl.style.display = "grid";
    }
  });
});
