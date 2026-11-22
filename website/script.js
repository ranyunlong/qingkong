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

const moodChoices = [...document.querySelectorAll('.mood-choice')];
const moodCharacters = [...document.querySelectorAll('#watch-dumpling, #mood-dumpling')];
const moodStages = [...document.querySelectorAll('.dumpling-stage')];
const moodCaptions = ['慢一点，也没关系', '休息一下，再出发', '此刻，刚刚好', '收集今天的小美好', '把快乐，抱个满怀'];
let selectedMood = 4;
let moodCycle;

function selectMood(value) {
  const choice = moodChoices.find((button) => Number(button.dataset.moodValue) === value);
  if (!choice) return;
  selectedMood = value;
  const name = choice.lastElementChild.textContent;
  moodCharacters.forEach((character) => {
    const drawing = choice.querySelector('svg').cloneNode(true);
    // Each inline copy needs its own gradient IDs, including after switching moods.
    drawing.querySelectorAll('[id]').forEach((definition) => {
      const previous = definition.id;
      definition.id = `${character.id}-${previous}`;
      drawing.querySelectorAll('[fill]').forEach((element) => {
        if (element.getAttribute('fill') === `url(#${previous})`) {
          element.setAttribute('fill', `url(#${definition.id})`);
        }
      });
    });
    character.classList.remove('greeting');
    character.dataset.mood = String(value);
    character.setAttribute('aria-label', `${name}的团子，点按打个招呼`);
    character.replaceChildren(drawing);
  });
  moodChoices.forEach((button) => {
    button.setAttribute('aria-pressed', String(button === choice));
  });
  document.querySelectorAll('[data-mood-caption]').forEach((caption) => {
    caption.textContent = moodCaptions[value - 1];
  });
}

function startMoodCycle() {
  clearInterval(moodCycle);
  moodCycle = setInterval(() => {
    if (document.hidden || !moodStages.some((stage) => stage.classList.contains('dumplings-in-view'))) return;
    if (document.activeElement?.closest('.mood-choices, .dumpling-stage button')) return;
    selectMood(selectedMood % 5 + 1);
  }, 8000);
}

moodChoices.forEach((button) => {
  button.addEventListener('click', () => {
    selectMood(Number(button.dataset.moodValue));
    startMoodCycle();
  });
});

moodCharacters.forEach((character) => {
  let greetingTimeout;
  character.addEventListener('click', () => {
    clearTimeout(greetingTimeout);
    character.classList.remove('greeting');
    void character.getBoundingClientRect();
    character.classList.add('greeting');
    greetingTimeout = setTimeout(() => character.classList.remove('greeting'), 1200);
    startMoodCycle();
  });
});

if (moodStages.length) {
  if ('IntersectionObserver' in window) {
    const moodObserver = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        entry.target.classList.toggle('dumplings-in-view', entry.isIntersecting);
      });
    });
    moodStages.forEach((stage) => moodObserver.observe(stage));
  } else {
    moodStages.forEach((stage) => stage.classList.add('dumplings-in-view'));
  }
  startMoodCycle();
}

// Website demonstrations stay local: no audio, records, uploads, or content API calls.
const companionDemo = document.querySelector('#companion-demo');
if (companionDemo) {
  const modeButtons = [...companionDemo.querySelectorAll('[data-companion-mode]')];
  const startButton = companionDemo.querySelector('#companion-start');
  const instruction = companionDemo.querySelector('#companion-instruction');
  const detail = companionDemo.querySelector('#companion-detail');
  let demoStartedAt = 0;
  let demoTimer;
  let lastPhase;

  function stopCompanionDemo() {
    clearInterval(demoTimer);
    companionDemo.dataset.state = 'rest';
    startButton.setAttribute('aria-pressed', 'false');
    startButton.textContent = '开始演示 ↗';
    instruction.textContent = companionDemo.dataset.mode === 'quiet' ? '什么也不做，也很好' : '准备好了，再慢慢开始';
    detail.textContent = companionDemo.dataset.mode === 'quiet' ? '团子在这里，安静陪着你' : '按舒服的节奏，不需要憋气';
    lastPhase = undefined;
  }

  function updateCompanionPhase() {
    const phase = (performance.now() - demoStartedAt) % 10000 < 4000 ? 'inhale' : 'exhale';
    if (phase === lastPhase) return;
    lastPhase = phase;
    instruction.textContent = phase === 'inhale' ? '轻轻吸气' : '慢慢呼气';
    detail.textContent = phase === 'inhale' ? '只吸到舒服的位置就好' : '不需要用力，也不用憋气';
  }

  modeButtons.forEach((button) => {
    button.disabled = false;
    button.addEventListener('click', () => {
      companionDemo.dataset.mode = button.dataset.companionMode;
      modeButtons.forEach((item) => item.setAttribute('aria-pressed', String(item === button)));
      stopCompanionDemo();
    });
  });
  startButton.hidden = false;
  startButton.addEventListener('click', () => {
    if (companionDemo.dataset.state === 'running') {
      stopCompanionDemo();
      return;
    }
    companionDemo.dataset.state = 'running';
    startButton.setAttribute('aria-pressed', 'true');
    startButton.textContent = '结束演示';
    if (companionDemo.dataset.mode === 'quiet') {
      instruction.textContent = '不用说什么，我在这里';
      detail.textContent = '安静待一会儿，按自己的节奏来';
    } else {
      demoStartedAt = performance.now();
      updateCompanionPhase();
      demoTimer = setInterval(updateCompanionPhase, 250);
    }
  });
  if ('IntersectionObserver' in window) {
    new IntersectionObserver(([entry]) => {
      companionDemo.classList.toggle('is-offscreen', !entry.isIntersecting);
      if (!entry.isIntersecting) stopCompanionDemo();
    }, { threshold: 0.1 }).observe(companionDemo);
  }
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) stopCompanionDemo();
  });
}

const postcardArt = document.querySelector('#postcard-art');
if (postcardArt) {
  const choices = [...document.querySelectorAll('[data-postcard-scenery]')];
  const character = document.querySelector('#postcard-character');
  choices.forEach((button) => {
    button.disabled = false;
    button.addEventListener('click', () => {
      const moonlight = button.dataset.postcardScenery === 'moonlight';
      postcardArt.dataset.scenery = button.dataset.postcardScenery;
      character.src = moonlight ? 'assets/mood-5.png' : 'assets/mood-4.png';
      character.alt = moonlight ? '月下湖畔中的开心团子' : '晨光草地中的微笑团子';
      document.querySelector('#postcard-message').textContent = moonlight ? '慢慢来，今晚也可以安心休息。' : '今天，也有属于自己的小美好。';
      choices.forEach((item) => item.setAttribute('aria-pressed', String(item === button)));
    });
  });
}
