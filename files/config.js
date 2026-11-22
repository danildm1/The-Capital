/* Настройки коммерческой части. Пока оплата НЕ подключена: paymentsEnabled = false.
   Включайте только после того, как сервер (см. docs/ARCHITECTURE.md) принимает заказы и подтверждает оплату. */
window.CAPITAL_CONFIG = {
  paymentsEnabled: false,
  checkoutEndpoint: '/api/checkout',
  currency: 'USD',
  provider: 'usdpay',
};
