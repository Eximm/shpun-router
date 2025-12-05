'use strict';
'require view';
'require rpc';

const callState = rpc.declare({
	object: 'shpun',
	method: 'state'
});

function badge(text, kind) {
	// kind: "ok", "warn", "err"
	let cls = 'label ';
	if (kind === 'ok')
		cls += 'label-success';
	else if (kind === 'warn')
		cls += 'label-warning';
	else if (kind === 'err')
		cls += 'label-danger';
	else
		cls += 'label-default';

	return E('span', { 'class': cls }, text);
}

return view.extend({
	title: _('Shpun VPN'),

	load: function () {
		return callState();
	},

	render: function (data) {
		data = data || {};

		const code      = (data.code || '').trim() || '—';
		const hasSub    = !!data.has_sub;
		const vpnReady  = !!data.vpn_ready;
		const vpnError  = data.vpn_error || '';
		const vpnIp     = (data.vpn_ip || '').trim();

		const fwCur     = (data.fw_current || '').trim();
		const fwLast    = (data.fw_latest  || '').trim();
		const hasFwInfo = fwCur || fwLast;
		const hasUpdate = fwCur && fwLast && (fwCur !== fwLast);

		// Общий статус
		let statusText, statusKind;

		if (!hasSub)
		{
			statusText = _('Router not linked to subscription');
			statusKind = 'warn';
		}
		else if (!vpnReady)
		{
			statusText = _('Subscription is linked, VPN is not active');
			statusKind = 'warn';
		}
		else
		{
			statusText = _('VPN is active and router is linked');
			statusKind = 'ok';
		}

		const rows = [];

		// Общий статус
		rows.push(E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, _('Status')),
			E('div', { 'class': 'cbi-value-field' }, [
				badge(vpnReady ? _('ACTIVE') : _('INACTIVE'), vpnReady ? 'ok' : 'warn'),
				E('span', { 'style': 'margin-left:8px' }, statusText)
			])
		]));

		// Router code
		rows.push(E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, _('Router code')),
			E('div',  { 'class': 'cbi-value-field' }, code)
		]));

		// Subscription
		rows.push(E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, _('Subscription')),
			E('div',  { 'class': 'cbi-value-field' },
				hasSub ? badge(_('LINKED'), 'ok') : badge(_('NOT LINKED'), 'warn')
			)
		]));

		// VPN IP (если есть)
		if (vpnIp) {
			rows.push(E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('VPN IP')),
				E('div',  { 'class': 'cbi-value-field' }, vpnIp)
			]));
		}

		// Firmware info (если агент/ucode что-то отдают)
		if (hasFwInfo) {
			let text = fwCur || _('unknown');
			if (fwLast && fwLast !== fwCur)
				text = text + ' > ' + fwLast;

			rows.push(E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Firmware')),
				E('div',  { 'class': 'cbi-value-field' }, [
					E('span', {}, text + ' '),
					hasUpdate
						? badge(_('UPDATE AVAILABLE'), 'warn')
						: badge(_('UP TO DATE'), 'ok'),
					E('span', { 'style': 'margin-left:8px' }),
					E('button', {
						'class': 'btn cbi-button cbi-button-action',
						'click': function (ev) {
							ev.preventDefault();
							// Пока просто открываем наш мастер — удобно и логично
							location.href = '/cgi-bin/luci/admin/services/shpun/wizard';
						}
					}, hasUpdate ? _('Update / details') : _('Details'))
				])
			]));
		}

		// Ошибка (если есть)
		if (vpnError) {
			rows.push(E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Error')),
				E('div',  { 'class': 'cbi-value-field' },
					badge(vpnError, 'err')
				)
			]));
		}

		return E('div', { 'class': 'cbi-section' }, rows);
	}
});
