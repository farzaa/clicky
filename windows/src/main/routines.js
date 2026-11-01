'use strict';
/*
 * Tiny scheduler for [ROUTINE:...] tasks. Checks once per tick whether a routine
 * is due; each routine runs at most once per scheduled minute.
 */
const { parseRoutineSchedule } = require('./tags');

function isDue(routine, date) {
  const schedule = routine.schedule || parseRoutineSchedule(routine.scheduleText);
  if (!schedule) return false;
  if (!schedule.days.includes(date.getDay())) return false;
  return date.getHours() === schedule.hour && date.getMinutes() === schedule.minute;
}

function runKey(date) {
  return `${date.getFullYear()}-${date.getMonth()}-${date.getDate()}-${date.getHours()}-${date.getMinutes()}`;
}

class RoutineScheduler {
  constructor({ getRoutines, onDue, now = () => new Date(), intervalMs = 20000 }) {
    this.getRoutines = getRoutines;
    this.onDue = onDue;
    this.now = now;
    this.intervalMs = intervalMs;
    this.lastRun = new Map();
    this.timer = null;
  }

  start() {
    this.stop();
    this.timer = setInterval(() => this.tick(), this.intervalMs);
    if (this.timer.unref) this.timer.unref();
  }

  stop() {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  tick() {
    const date = this.now();
    const key = runKey(date);
    for (const routine of this.getRoutines()) {
      if (routine.enabled === false) continue;
      if (!isDue(routine, date)) continue;
      if (this.lastRun.get(routine.id) === key) continue;
      this.lastRun.set(routine.id, key);
      this.onDue(routine);
    }
  }
}

module.exports = { RoutineScheduler, isDue, runKey };
