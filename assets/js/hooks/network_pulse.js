const MAX_PARTICLES = 220

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value))
}

function lerp(start, end, factor) {
  return start + (end - start) * factor
}

export default {
  mounted() {
    this.canvas = document.createElement("canvas")
    this.canvas.className = "h-full w-full"
    this.ctx = this.canvas.getContext("2d")
    this.el.appendChild(this.canvas)

    this.particles = []
    this.snapshot = {
      mempool_count: 0,
      block_tx_count: 0,
      block_height: null,
      new_block: false,
      rpc_online: false
    }
    this.visuals = {
      mempoolDensity: 0.12,
      blockFill: 0.18,
      blockGlow: 0,
      inhale: 0
    }
    this.lastTime = performance.now()
    this.lastStampAt = 0

    this.handleResize = this.handleResize.bind(this)
    this.animate = this.animate.bind(this)

    window.addEventListener("resize", this.handleResize)
    this.handleResize()

    this.handleEvent("network_pulse_snapshot", (snapshot) => {
      this.snapshot = snapshot
      this.visuals.mempoolDensity = this.normalizeMempool(snapshot.mempool_count)

      if (snapshot.new_block) {
        this.visuals.blockFill = this.normalizeBlock(snapshot.block_tx_count)
        this.visuals.blockGlow = 1
        this.lastStampAt = performance.now()
        this.seedStampParticles()
      }
    })

    this.animationFrame = requestAnimationFrame(this.animate)
  },

  destroyed() {
    cancelAnimationFrame(this.animationFrame)
    window.removeEventListener("resize", this.handleResize)
  },

  handleResize() {
    const rect = this.el.getBoundingClientRect()
    const width = rect.width || window.innerWidth
    const height = rect.height || window.innerHeight
    const dpr = Math.min(window.devicePixelRatio || 1, 2)

    this.canvas.width = Math.floor(width * dpr)
    this.canvas.height = Math.floor(height * dpr)
    this.canvas.style.width = `${width}px`
    this.canvas.style.height = `${height}px`
    this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0)

    this.width = width
    this.height = height
    this.center = { x: width / 2, y: height / 2 }
    this.blockSize = Math.min(width, height) * 0.18
    this.outerRadius = Math.min(width, height) * 0.34
  },

  animate(now) {
    const delta = Math.min((now - this.lastTime) / 1000, 0.05)
    this.lastTime = now

    this.step(delta, now)
    this.draw(now)

    this.animationFrame = requestAnimationFrame(this.animate)
  },

  step(delta, now) {
    const idleBreath = (Math.sin(now * 0.0012) + 1) * 0.5
    this.visuals.inhale = lerp(this.visuals.inhale, idleBreath, 0.04)

    const stampDecay = clamp(1 - (now - this.lastStampAt) / 2200, 0, 1)
    this.visuals.blockGlow = lerp(this.visuals.blockGlow, stampDecay, 0.09)

    const desiredParticles = Math.round(25 + this.visuals.mempoolDensity * (MAX_PARTICLES - 25))

    if (this.particles.length < desiredParticles && Math.random() < 0.65) {
      this.spawnParticle()
    }

    if (this.particles.length > desiredParticles) {
      this.particles.splice(desiredParticles)
    }

    this.particles = this.particles.filter((particle) => {
      particle.life -= delta * particle.fadeSpeed
      particle.progress += delta * particle.speed
      particle.x = lerp(particle.startX, this.center.x, particle.progress)
      particle.y = lerp(particle.startY, this.center.y, particle.progress)
      return particle.life > 0 && particle.progress < 1.08
    })
  },

  spawnParticle() {
    const angle = Math.random() * Math.PI * 2
    const radius = this.outerRadius + 40 + Math.random() * 120

    this.particles.push({
      startX: this.center.x + Math.cos(angle) * radius,
      startY: this.center.y + Math.sin(angle) * radius,
      x: 0,
      y: 0,
      progress: Math.random() * 0.12,
      speed: 0.16 + Math.random() * 0.45 + this.visuals.mempoolDensity * 0.5,
      radius: 0.8 + Math.random() * 2.8,
      life: 0.7 + Math.random() * 0.8,
      fadeSpeed: 0.5 + Math.random() * 0.8
    })
  },

  seedStampParticles() {
    for (let index = 0; index < 44; index += 1) {
      const angle = (Math.PI * 2 * index) / 44

      this.particles.push({
        startX: this.center.x + Math.cos(angle) * (this.blockSize * 0.45),
        startY: this.center.y + Math.sin(angle) * (this.blockSize * 0.45),
        x: 0,
        y: 0,
        progress: -0.24,
        speed: 0.6 + Math.random() * 0.8,
        radius: 1.4 + Math.random() * 2.6,
        life: 0.8 + Math.random() * 0.5,
        fadeSpeed: 1 + Math.random() * 0.7
      })
    }
  },

  draw(now) {
    const ctx = this.ctx
    const width = this.width
    const height = this.height

    ctx.clearRect(0, 0, width, height)

    this.drawBackground(ctx, width, height, now)
    this.drawBreathRings(ctx, now)
    this.drawParticles(ctx)
    this.drawBlock(ctx, now)
  },

  drawBackground(ctx, width, height, now) {
    const gradient = ctx.createRadialGradient(
      this.center.x,
      this.center.y,
      0,
      this.center.x,
      this.center.y,
      Math.max(width, height) * 0.75
    )

    gradient.addColorStop(0, "rgba(24, 72, 111, 0.24)")
    gradient.addColorStop(0.35, "rgba(7, 25, 47, 0.28)")
    gradient.addColorStop(1, "rgba(1, 4, 11, 1)")

    ctx.fillStyle = gradient
    ctx.fillRect(0, 0, width, height)

    const halo = 0.18 + this.visuals.inhale * 0.1
    ctx.save()
    ctx.globalAlpha = halo
    ctx.fillStyle = "rgba(86, 224, 255, 0.12)"
    ctx.beginPath()
    ctx.arc(this.center.x, this.center.y, this.outerRadius + 120 + Math.sin(now * 0.001) * 18, 0, Math.PI * 2)
    ctx.fill()
    ctx.restore()
  },

  drawBreathRings(ctx, now) {
    const inhaleRadius = this.outerRadius * (0.92 + this.visuals.inhale * 0.18)
    const exhaleRadius = this.outerRadius * (1.12 + (1 - this.visuals.inhale) * 0.15)

    ;[
      { radius: exhaleRadius, stroke: "rgba(123, 211, 255, 0.08)", lineWidth: 1.5 },
      { radius: inhaleRadius, stroke: "rgba(110, 255, 214, 0.12)", lineWidth: 1.5 }
    ].forEach((ring) => {
      ctx.beginPath()
      ctx.strokeStyle = ring.stroke
      ctx.lineWidth = ring.lineWidth
      ctx.arc(this.center.x, this.center.y, ring.radius, 0, Math.PI * 2)
      ctx.stroke()
    })

    ctx.save()
    ctx.strokeStyle = "rgba(255, 163, 93, 0.12)"
    ctx.lineWidth = 1
    ctx.setLineDash([6, 14])
    ctx.beginPath()
    ctx.arc(this.center.x, this.center.y, this.outerRadius * 0.74, now * 0.00025, now * 0.00025 + Math.PI * 1.4)
    ctx.stroke()
    ctx.restore()
  },

  drawParticles(ctx) {
    this.particles.forEach((particle) => {
      const alpha = clamp((1 - particle.progress) * particle.life, 0, 1)

      ctx.beginPath()
      ctx.fillStyle = `rgba(141, 243, 255, ${alpha * 0.8})`
      ctx.arc(particle.x, particle.y, particle.radius, 0, Math.PI * 2)
      ctx.fill()
    })
  },

  drawBlock(ctx, now) {
    const size = this.blockSize
    const x = this.center.x - size / 2
    const y = this.center.y - size / 2
    const pulse = 1 + this.visuals.blockGlow * 0.06 + Math.sin(now * 0.0016) * 0.01
    const scaled = size * pulse
    const scaledX = this.center.x - scaled / 2
    const scaledY = this.center.y - scaled / 2

    ctx.save()
    ctx.shadowBlur = 35 + this.visuals.blockGlow * 45
    ctx.shadowColor = "rgba(255, 163, 93, 0.35)"
    ctx.fillStyle = "rgba(8, 13, 25, 0.86)"
    ctx.fillRect(scaledX, scaledY, scaled, scaled)
    ctx.restore()

    const fillHeight = size * clamp(this.visuals.blockFill, 0.06, 1)
    const fillY = y + size - fillHeight
    const fillGradient = ctx.createLinearGradient(x, y + size, x, y)
    fillGradient.addColorStop(0, "rgba(255, 133, 71, 0.92)")
    fillGradient.addColorStop(1, "rgba(255, 218, 145, 0.72)")

    ctx.fillStyle = fillGradient
    ctx.fillRect(x, fillY, size, fillHeight)

    ctx.strokeStyle = `rgba(230, 247, 255, ${0.42 + this.visuals.blockGlow * 0.35})`
    ctx.lineWidth = 2
    ctx.strokeRect(x, y, size, size)

    ctx.strokeStyle = "rgba(103, 232, 249, 0.18)"
    ctx.lineWidth = 1
    ctx.strokeRect(x - 8, y - 8, size + 16, size + 16)
  },

  normalizeMempool(mempoolCount) {
    const safeCount = Math.max(Number(mempoolCount) || 0, 1)
    return clamp(Math.log10(safeCount + 1) / 6, 0.06, 1)
  },

  normalizeBlock(blockTxCount) {
    const safeCount = Math.max(Number(blockTxCount) || 0, 1)
    return clamp(Math.log10(safeCount + 1) / 6, 0.08, 1)
  }
}
