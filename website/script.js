const scenes = {
  forest: { image: 'assets/forest.jpg', alt: '阳光穿过林间，照亮绿色森林', description: '仿佛走进一片森林，给呼吸留一点空间。' },
  ocean: { image: 'assets/ocean.jpg', alt: '柔软沙滩与蔚蓝海岸', description: '让思绪随着海浪，慢慢回到舒服的节奏。' },
  night: { image: 'assets/night.jpg', alt: '群山之上的宁静星空', description: '在安静的星夜里，轻轻放下今天的忙碌。' },
};

const root = document.documentElement;
const hero = document.querySelector('.hero');
const header = document.querySelector('.site-header');
const sections = [...document.querySelectorAll('main > section[id]')];
const sectionLinks = [...document.querySelectorAll('.nav-links a[href^="#"]')];
const scrollVisuals = [...document.querySelectorAll('.trend-visual, .mood-main, .scene-showcase, .privacy-symbol, .availability-icon')];
let sceneRequest = 0;
let sceneTransition;

document.querySelectorAll('.scene-switcher button').forEach((button) => {
  button.addEventListener('click', async () => {
    const scene = scenes[button.dataset.scene];
    if (!scene) return;
    const request = ++sceneRequest;
    const showcase = document.querySelector('.scene-showcase');
    if (showcase.dataset.scene === button.dataset.scene) return;
    const nextImage = new Image();
    nextImage.src = scene.image;
    try {
      await nextImage.decode();
    } catch {
      return;
    }
    if (request !== sceneRequest) return;

    sceneTransition?.cancel();
    showcase.querySelector('.scene-image-outgoing')?.remove();
    const image = document.querySelector('#scene-image');
    const outgoing = image.cloneNode();
    outgoing.removeAttribute('id');
    outgoing.alt = '';
    outgoing.setAttribute('aria-hidden', 'true');
    outgoing.classList.add('scene-image-outgoing');
    image.src = scene.image;
    image.alt = scene.alt;
    document.querySelector('#scene-description').textContent = scene.description;
    showcase.dataset.scene = button.dataset.scene;
    document.querySelectorAll('.scene-switcher button').forEach((item) => {
      item.setAttribute('aria-pressed', String(item === button));
    });
    if (typeof outgoing.animate === 'function') {
      image.after(outgoing);
      sceneTransition = outgoing.animate(
        [{ opacity: 1 }, { opacity: 0 }],
        { duration: 550, easing: 'ease-in-out' },
      );
      sceneTransition.onfinish = () => outgoing.remove();
    }
  });
});

function updateScroll() {
  const scrollRange = root.scrollHeight - window.innerHeight;
  const progress = scrollRange > 0 ? Math.min(1, Math.max(0, window.scrollY / scrollRange)) : 0;
  header?.classList.toggle('is-scrolled', window.scrollY > 16);
  root.style.setProperty('--reading-progress', progress);
  if (hero) {
    const rect = hero.getBoundingClientRect();
    const inView = rect.bottom > 0 && rect.top < window.innerHeight;
    hero.classList.toggle('hero-in-view', inView);
    const distance = Math.min(Math.max(-rect.top, 0), rect.height);
    const shift = -Math.min(distance * .045, window.innerWidth <= 760 ? 14 : 28);
    hero.style.setProperty('--hero-shift', `${shift}px`);
  }
  scrollVisuals.forEach((element) => {
    const rect = element.getBoundingClientRect();
    const travel = window.innerHeight * .65;
    const progress = Math.min(1, Math.max(0, (window.innerHeight * .9 - rect.top) / Math.max(travel, 1)));
    element.style.setProperty('--section-progress', progress.toFixed(4));
  });
  let activeSection;
  sections.forEach((section) => {
    if (section.getBoundingClientRect().top <= 150) activeSection = section.id;
  });
  sectionLinks.forEach((link) => {
    if (link.hash === `#${activeSection}`) link.setAttribute('aria-current', 'location');
    else link.removeAttribute('aria-current');
  });
}

let scrollFrame = 0;
function scheduleScroll() {
  if (scrollFrame) return;
  scrollFrame = requestAnimationFrame(() => {
    scrollFrame = 0;
    updateScroll();
  });
}
window.addEventListener('scroll', scheduleScroll, { passive: true });
window.addEventListener('resize', scheduleScroll);
window.addEventListener('load', scheduleScroll);
root.classList.add('motion-ready');
updateScroll();

if ('IntersectionObserver' in window) {
  const observer = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      entry.target.classList.toggle('is-visible', entry.isIntersecting);
    });
    scheduleScroll();
  }, { threshold: 0.12 });
  document.querySelectorAll('.feature-grid, .small-features').forEach((group) => {
    [...group.children].forEach((element, index) => {
      element.style.setProperty('--reveal-delay', `${index * 100}ms`);
    });
  });
  document.querySelector('.trend-visual path[stroke="#588cb5"]')?.classList.add('trend-line');
  document.querySelector('.trend-line')?.setAttribute('pathLength', '1');
  document.querySelectorAll('.reveal').forEach((element) => {
    element.classList.add('will-reveal');
    observer.observe(element);
  });
}
