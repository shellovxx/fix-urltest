import { Forkop } from '../types';

export function getHealthLabel(health: Forkop.HealthInfo) {
  if (health.checking) return _('Checking transfer');
  switch (health.status) {
    case 'verified':
      return _('Transfer verified');
    case 'failed':
      return _('Transfer check failed');
    case 'unavailable':
      return _('No verified server available');
    default:
      return _('Awaiting transfer check');
  }
}

export function getHealthReason(health: Forkop.HealthInfo) {
  if (!health.reason) return '';
  if (health.reason.startsWith('http-'))
    return `HTTP ${health.reason.slice(5)}`;
  if (health.reason === 'timeout' || health.reason === 'probe-timeout')
    return health.bytes
      ? _('Transfer stalled before completion')
      : _('Transfer timed out');
  if (health.reason === 'partial') return _('Incomplete payload');
  if (health.reason === 'tls') return _('TLS verification failed');
  if (health.reason === 'connection') return _('Proxy connection failed');
  if (health.reason === 'latency-unavailable')
    return _('Short latency test failed');
  if (health.reason === 'controller-unavailable')
    return _('Selection controller is unavailable');
  return _('Transfer probe is unavailable');
}
