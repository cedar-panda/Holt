/**
 * Holt PWA — shared avatar crop selection for characters and the user.
 * The crop window always stays inside the source image bounds.
 */

let cropModal = null;
let cropImage = null;
let cropViewport = null;
let cropZoom = null;
let cropZoomValue = null;
let cropConfirm = null;
let activeSession = null;

function ensureCropModal() {
  if (cropModal) return;

  cropModal = document.createElement("div");
  cropModal.className = "avatar-cropper-modal";
  cropModal.hidden = true;
  cropModal.setAttribute("role", "dialog");
  cropModal.setAttribute("aria-modal", "true");
  cropModal.innerHTML = `
    <header class="avatar-cropper-header">
      <button class="avatar-cropper-cancel" type="button" aria-label="取消裁剪">×</button>
      <h2 class="avatar-cropper-title">裁剪頭像</h2>
      <span class="avatar-cropper-header-spacer" aria-hidden="true"></span>
    </header>
    <div class="avatar-cropper-viewport" aria-label="頭像裁剪區，可拖曳圖片調整位置">
      <img class="avatar-cropper-image" alt="" draggable="false">
      <div class="avatar-cropper-window" aria-hidden="true"></div>
    </div>
    <p class="avatar-cropper-hint">拖曳移動圖片 · 滑桿或雙指縮放</p>
    <label class="avatar-cropper-zoom-label">
      <span aria-hidden="true">−</span>
      <input class="avatar-cropper-zoom" type="range" min="1" max="3" step="0.01" value="1" aria-label="縮放圖片">
      <span aria-hidden="true">＋</span>
      <output class="avatar-cropper-zoom-value">100%</output>
    </label>
    <div class="avatar-cropper-actions">
      <button class="btn-plain avatar-cropper-cancel-secondary" type="button">取消</button>
      <button class="btn-primary avatar-cropper-confirm" type="button">確認</button>
    </div>
  `;
  document.body.appendChild(cropModal);

  cropImage = cropModal.querySelector(".avatar-cropper-image");
  cropViewport = cropModal.querySelector(".avatar-cropper-viewport");
  cropZoom = cropModal.querySelector(".avatar-cropper-zoom");
  cropZoomValue = cropModal.querySelector(".avatar-cropper-zoom-value");
  cropConfirm = cropModal.querySelector(".avatar-cropper-confirm");

  const cancel = () => finishCrop(null);
  cropModal.querySelector(".avatar-cropper-cancel").addEventListener("click", cancel);
  cropModal.querySelector(".avatar-cropper-cancel-secondary").addEventListener("click", cancel);
  cropConfirm.addEventListener("click", confirmCrop);
  cropZoom.addEventListener("input", () => {
    if (!activeSession) return;
    activeSession.zoom = Number(cropZoom.value);
    renderCropImage();
  });

  const pointers = new Map();
  let dragStart = null;
  let pinchStart = null;

  cropViewport.addEventListener("pointerdown", (event) => {
    if (!activeSession) return;
    cropViewport.setPointerCapture(event.pointerId);
    pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
    if (pointers.size === 1) {
      dragStart = {
        x: event.clientX,
        y: event.clientY,
        offsetX: activeSession.offsetX,
        offsetY: activeSession.offsetY,
      };
    } else if (pointers.size === 2) {
      dragStart = null;
      pinchStart = { distance: pointerDistance(pointers), zoom: activeSession.zoom };
    }
  });

  cropViewport.addEventListener("pointermove", (event) => {
    if (!activeSession || !pointers.has(event.pointerId)) return;
    pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
    if (pointers.size >= 2 && pinchStart) {
      const ratio = pointerDistance(pointers) / Math.max(1, pinchStart.distance);
      activeSession.zoom = Math.max(1, Math.min(3, pinchStart.zoom * ratio));
      cropZoom.value = activeSession.zoom.toFixed(2);
      renderCropImage();
    } else if (pointers.size === 1 && dragStart) {
      activeSession.offsetX = dragStart.offsetX + event.clientX - dragStart.x;
      activeSession.offsetY = dragStart.offsetY + event.clientY - dragStart.y;
      renderCropImage();
    }
  });

  const endPointer = (event) => {
    pointers.delete(event.pointerId);
    if (pointers.size < 2) pinchStart = null;
    if (pointers.size === 1) {
      const point = [...pointers.values()][0];
      dragStart = {
        x: point.x,
        y: point.y,
        offsetX: activeSession?.offsetX || 0,
        offsetY: activeSession?.offsetY || 0,
      };
    } else if (!pointers.size) {
      dragStart = null;
    }
  };
  cropViewport.addEventListener("pointerup", endPointer);
  cropViewport.addEventListener("pointercancel", endPointer);
  cropViewport.addEventListener("wheel", (event) => {
    if (!activeSession) return;
    event.preventDefault();
    activeSession.zoom = Math.max(1, Math.min(3, activeSession.zoom - event.deltaY * 0.002));
    cropZoom.value = activeSession.zoom.toFixed(2);
    renderCropImage();
  }, { passive: false });

  window.addEventListener("keydown", (event) => {
    if (!activeSession || event.key !== "Escape") return;
    finishCrop(null);
  });
}

function pointerDistance(pointers) {
  const points = [...pointers.values()];
  return Math.hypot(points[0].x - points[1].x, points[0].y - points[1].y);
}

function renderCropImage() {
  if (!activeSession || !cropViewport || !cropImage) return;
  const side = cropViewport.clientWidth;
  if (!side || !activeSession.image.naturalWidth) return;

  const baseScale = Math.max(
    side / activeSession.image.naturalWidth,
    side / activeSession.image.naturalHeight,
  );
  const scale = baseScale * activeSession.zoom;
  const renderedWidth = activeSession.image.naturalWidth * scale;
  const renderedHeight = activeSession.image.naturalHeight * scale;
  const maxX = Math.max(0, (renderedWidth - side) / 2);
  const maxY = Math.max(0, (renderedHeight - side) / 2);
  activeSession.offsetX = Math.max(-maxX, Math.min(maxX, activeSession.offsetX));
  activeSession.offsetY = Math.max(-maxY, Math.min(maxY, activeSession.offsetY));

  cropImage.style.width = `${renderedWidth}px`;
  cropImage.style.height = `${renderedHeight}px`;
  cropImage.style.transform = `translate(calc(-50% + ${activeSession.offsetX}px), calc(-50% + ${activeSession.offsetY}px))`;
  cropZoomValue.textContent = `${Math.round(activeSession.zoom * 100)}%`;
}

async function confirmCrop() {
  if (!activeSession || !cropViewport || !cropConfirm) return;
  cropConfirm.disabled = true;
  try {
    const side = cropViewport.clientWidth;
    const baseScale = Math.max(
      side / activeSession.image.naturalWidth,
      side / activeSession.image.naturalHeight,
    );
    const scale = baseScale * activeSession.zoom;
    const sourceSide = side / scale;
    const sourceLeft = Math.max(
      0,
      Math.min(
        activeSession.image.naturalWidth - sourceSide,
        activeSession.image.naturalWidth / 2 - activeSession.offsetX / scale - sourceSide / 2,
      ),
    );
    const sourceTop = Math.max(
      0,
      Math.min(
        activeSession.image.naturalHeight - sourceSide,
        activeSession.image.naturalHeight / 2 - activeSession.offsetY / scale - sourceSide / 2,
      ),
    );

    const canvas = document.createElement("canvas");
    canvas.width = 512;
    canvas.height = 512;
    const context = canvas.getContext("2d");
    context.drawImage(
      activeSession.image,
      sourceLeft,
      sourceTop,
      sourceSide,
      sourceSide,
      0,
      0,
      512,
      512,
    );
    finishCrop(canvas.toDataURL("image/webp", 0.88));
  } catch (error) {
    cropConfirm.disabled = false;
    throw error;
  }
}

function finishCrop(result) {
  if (!activeSession) return;
  const resolve = activeSession.resolve;
  const url = activeSession.objectUrl;
  activeSession = null;
  cropModal.hidden = true;
  cropConfirm.disabled = false;
  cropImage.removeAttribute("src");
  if (url) URL.revokeObjectURL(url);
  resolve(result);
}

export function openAvatarCropper(file, { title = "裁剪頭像" } = {}) {
  ensureCropModal();
  if (activeSession) finishCrop(null);

  return new Promise((resolve, reject) => {
    const objectUrl = URL.createObjectURL(file);
    const image = new Image();
    activeSession = {
      image,
      objectUrl,
      resolve,
      reject,
      zoom: 1,
      offsetX: 0,
      offsetY: 0,
    };
    cropModal.querySelector(".avatar-cropper-title").textContent = title;
    cropImage.onload = () => {
      if (!activeSession || activeSession.image !== image) return;
      cropModal.hidden = false;
      cropZoom.value = "1";
      requestAnimationFrame(renderCropImage);
    };
    image.onerror = () => {
      const error = new Error("無法讀取圖片");
      finishCrop(null);
      reject(error);
    };
    cropImage.src = objectUrl;
    image.src = objectUrl;
  });
}
