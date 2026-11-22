(function () {
  'use strict';
  var root = document.documentElement;
  root.classList.add('js');

  // ---------- Мобильное меню ----------
  var btn = document.querySelector('.menu-btn');
  var nav = document.getElementById('site-nav');
  if (btn && nav) {
    var setOpen = function (open) {
      nav.setAttribute('data-open', open ? 'true' : 'false');
      btn.setAttribute('aria-expanded', open ? 'true' : 'false');
      btn.textContent = open ? 'Закрыть' : 'Меню';
    };
    setOpen(false);
    btn.addEventListener('click', function () { setOpen(nav.getAttribute('data-open') !== 'true'); });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && nav.getAttribute('data-open') === 'true') { setOpen(false); btn.focus(); }
    });
    nav.addEventListener('click', function (e) { if (e.target.closest('a')) setOpen(false); });
  }

  // ---------- Покупка ----------
  // Цены здесь только для показа. Настоящую цену и состав заказа определяет сервер по своей базе.
  var CATALOG = {
    foundations: { title: 'THE FOUNDATIONS', price: 2 },
    business: { title: 'THE BUSINESS', price: 2 },
    capital: { title: 'THE CAPITAL', price: 2 },
    casefiles: { title: 'THE CASE FILES', price: 2 },
    playbook: { title: 'THE PLAYBOOK', price: 2 },
    all: { title: 'Все пять направлений', price: 8 }
  };
  var cfg = window.CAPITAL_CONFIG || { paymentsEnabled: false };
  var dialog = null, lastFocus = null;

  function build() {
    if (dialog) return dialog;
    dialog = document.createElement('dialog');
    dialog.className = 'buy';
    dialog.setAttribute('aria-labelledby', 'buy-title');
    dialog.innerHTML =
      '<form method="dialog" class="buy__body" novalidate>' +
      '<h2 id="buy-title"></h2><div class="buy__content"></div>' +
      '<p class="buy__error" role="alert"></p>' +
      '<div class="buy__actions"></div></form>';
    document.body.appendChild(dialog);
    dialog.addEventListener('close', function () { if (lastFocus && lastFocus.focus) lastFocus.focus(); });
    dialog.addEventListener('click', function (e) { if (e.target === dialog) dialog.close(); });
    return dialog;
  }

  function el(tag, cls, text) { var n = document.createElement(tag); if (cls) n.className = cls; if (text) n.textContent = text; return n; }

  function open(slug, trigger) {
    var item = CATALOG[slug];
    if (!item) return;
    lastFocus = trigger;
    var d = build();
    var title = d.querySelector('#buy-title');
    var content = d.querySelector('.buy__content');
    var err = d.querySelector('.buy__error');
    var actions = d.querySelector('.buy__actions');
    content.textContent = ''; actions.textContent = ''; err.textContent = '';

    var row = el('div', 'buy__item');
    row.appendChild(el('span', '', item.title));
    row.appendChild(el('span', '', '$' + item.price));

    var close = el('button', 'btn btn--plain btn--small', 'Закрыть');
    close.type = 'button';
    close.addEventListener('click', function () { d.close(); });

    if (!cfg.paymentsEnabled) {
      title.textContent = 'Продажи ещё не открыты';
      content.appendChild(row);
      content.appendChild(el('p', '', 'Мы публикуем первые материалы библиотеки. Оплата через usdpay будет подключена к моменту открытия продаж: до этого момента купить материалы нельзя, и списаний не происходит.'));
      actions.appendChild(close);
    } else {
      title.textContent = 'Оформление заказа';
      content.appendChild(row);
      content.appendChild(el('p', '', 'Укажите email: на него придёт доступ к купленным материалам.'));
      var label = el('label', '', 'Email'); label.setAttribute('for', 'buy-email');
      var input = el('input'); input.type = 'email'; input.id = 'buy-email'; input.autocomplete = 'email'; input.required = true;
      content.appendChild(label); content.appendChild(input);
      var go = el('button', 'btn btn--small', 'Перейти к оплате'); go.type = 'button';
      go.addEventListener('click', function () { checkout(slug, input, err, go); });
      actions.appendChild(go); actions.appendChild(close);
    }
    if (typeof d.showModal === 'function') d.showModal(); else d.setAttribute('open', '');
  }

  // Заказ создаёт сервер: он читает цену из своей базы и возвращает ссылку на оплату у провайдера.
  function checkout(slug, input, err, go) {
    var email = (input.value || '').trim();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) { err.textContent = 'Введите корректный email.'; input.focus(); return; }
    err.textContent = ''; go.disabled = true;
    fetch(cfg.checkoutEndpoint, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ items: [slug], email: email })
    }).then(function (r) { return r.json().then(function (j) { return { ok: r.ok, body: j }; }); })
      .then(function (res) {
        if (res.ok && res.body && typeof res.body.url === 'string' && /^https:\/\//.test(res.body.url)) { window.location.assign(res.body.url); return; }
        throw new Error('checkout');
      })
      .catch(function () { err.textContent = 'Не удалось создать заказ. Попробуйте ещё раз позже.'; go.disabled = false; });
  }

  document.addEventListener('click', function (e) {
    var t = e.target.closest('[data-buy]');
    if (!t) return;
    e.preventDefault();
    open(t.getAttribute('data-buy'), t);
  });
})();
