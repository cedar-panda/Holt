/**
 * Holt PWA — 用量監控面板
 * 照搬 Flutter usage_dashboard_screen.dart
 */

import { $, registerTabHandler } from "./app.js";
import { getUsageSummary, getDailyUsage, getUsageByModel } from "./db.js";

const periodBar = $("#usagePeriodBar");
const summaryArea = $("#usageSummaryArea");
const chartArea = $("#usageChartArea");
const modelArea = $("#usageModelArea");

let currentPeriod = 0; // 0=今天 1=本週 2=本月
const periodLabels = ["今天", "本週", "本月"];

function getRange(period) {
  const now = new Date();
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const tomorrow = new Date(today);
  tomorrow.setDate(tomorrow.getDate() + 1);

  switch (period) {
    case 0: return [today, tomorrow];
    case 1: {
      const weekStart = new Date(today);
      weekStart.setDate(weekStart.getDate() - ((weekStart.getDay() + 6) % 7)); // Monday
      return [weekStart, tomorrow];
    }
    case 2: {
      const monthStart = new Date(now.getFullYear(), now.getMonth(), 1);
      return [monthStart, tomorrow];
    }
    default: return [today, tomorrow];
  }
}

function formatK(n) {
  if (n < 1000) return String(n);
  if (n < 10000) return (n / 1000).toFixed(1) + "k";
  return Math.round(n / 1000) + "k";
}

function formatCost(cost) {
  if (cost < 0.001) return "< $0.001";
  return "$" + cost.toFixed(4);
}

function esc(s) {
  const d = document.createElement("div");
  d.textContent = s;
  return d.innerHTML;
}

// ═══ Render ═══

async function renderUsage() {
  const [from, to] = getRange(currentPeriod);

  // 更新 period bar
  periodBar?.querySelectorAll(".usage-period-btn").forEach((btn) => {
    btn.classList.toggle("is-active", Number(btn.dataset.period) === currentPeriod);
  });

  const [summary, daily, models] = await Promise.all([
    getUsageSummary(from, to),
    getDailyUsage(from, to),
    getUsageByModel(from, to),
  ]);

  renderSummary(summary);
  renderChart(daily);
  renderModels(models);
}

function renderSummary(s) {
  if (!summaryArea) return;
  const cost = s.totalCost || 0;
  const prompt = s.totalPrompt || 0;
  const completion = s.totalCompletion || 0;
  const cacheHit = s.totalCacheHit || 0;
  const requests = s.totalRequests || 0;

  summaryArea.innerHTML = `
    <div class="usage-cost-card">
      <span class="usage-cost-value">${formatCost(cost)}</span>
      <span class="usage-cost-label">${esc(periodLabels[currentPeriod])}費用合計</span>
    </div>
    <div class="usage-mini-row">
      <div class="usage-mini-card"><span class="usage-mini-value">${requests}</span><span class="usage-mini-label">請求</span></div>
      <div class="usage-mini-card"><span class="usage-mini-value">${formatK(prompt + completion)}</span><span class="usage-mini-label">tokens</span></div>
      <div class="usage-mini-card"><span class="usage-mini-value">${cacheHit > 0 ? formatK(cacheHit) : "—"}</span><span class="usage-mini-label">快取命中</span></div>
    </div>`;
}

function renderChart(daily) {
  if (!chartArea) return;
  if (daily.length <= 1) { chartArea.innerHTML = ""; return; }

  const costs = daily.map((d) => d.cost);
  const maxCost = Math.max(...costs);
  if (maxCost === 0) { chartArea.innerHTML = ""; return; }

  const W = 320, H = 120, PB = 18;
  const chartH = H - PB;
  const stepX = (W - 10) / (daily.length - 1);

  // Build SVG
  let points = "", fill = `0,${chartH} `;
  const dots = [];
  const labels = [];

  for (let i = 0; i < daily.length; i++) {
    const x = i * stepX;
    const y = chartH - (costs[i] / maxCost * chartH);
    points += `${x},${y} `;
    fill += `${x},${y} `;
    dots.push(`<circle cx="${x}" cy="${y}" r="3" fill="var(--accent)"/>`);
    if (daily.length <= 7 || i % 2 === 0 || i === daily.length - 1) {
      const dateLabel = daily[i].date.substring(5);
      labels.push(`<text x="${x}" y="${chartH + 14}" text-anchor="middle" fill="var(--ink-soft)" font-size="9">${dateLabel}</text>`);
    }
  }
  fill += `${(daily.length - 1) * stepX},${chartH}`;

  chartArea.innerHTML = `
    <div class="usage-chart-card">
      <svg viewBox="0 0 ${W} ${H}" class="usage-chart-svg">
        <defs>
          <linearGradient id="usageGrad" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stop-color="var(--accent)" stop-opacity="0.2"/>
            <stop offset="100%" stop-color="var(--accent)" stop-opacity="0.02"/>
          </linearGradient>
        </defs>
        ${[0, 0.5, 1].map((f) => `<line x1="0" y1="${chartH * f}" x2="${W - 10}" y2="${chartH * f}" stroke="var(--ink-faint)" stroke-opacity="0.15" stroke-width="0.5"/>`).join("")}
        <polygon points="${fill}" fill="url(#usageGrad)"/>
        <polyline points="${points}" fill="none" stroke="var(--accent)" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
        ${dots.join("")}
        ${labels.join("")}
      </svg>
    </div>`;
}

function renderModels(models) {
  if (!modelArea) return;
  if (!models.length) {
    modelArea.innerHTML = `<div class="usage-no-data">本時段暫無用量記錄</div>`;
    return;
  }

  const rows = models.map((m) => {
    const shortName = m.model.includes("/") ? m.model.split("/").pop() : m.model;
    return `
      <div class="usage-model-row">
        <div class="usage-model-info">
          <span class="usage-model-name">${esc(shortName)}</span>
          <span class="usage-model-detail">${m.requests} 次 · ${formatK(m.totalTokens)} tokens</span>
        </div>
        <span class="usage-model-cost">${formatCost(m.cost)}</span>
      </div>`;
  }).join("");

  modelArea.innerHTML = `
    <div class="usage-model-section">
      <span class="usage-section-label">模型分佈</span>
      ${rows}
    </div>`;
}

// ═══ Event bindings ═══

periodBar?.addEventListener("click", (e) => {
  const btn = e.target.closest("[data-period]");
  if (!btn) return;
  currentPeriod = Number(btn.dataset.period);
  renderUsage();
});

registerTabHandler(1, renderUsage);
