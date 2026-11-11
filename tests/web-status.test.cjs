const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const html = fs.readFileSync(path.join(__dirname, '../web/index.html'), 'utf8');
const names = ['escapeHtml', 'formatDateTime', 'hostHealth', 'deploymentHealth',
    'renderTabAttention', 'renderTable', 'renderHostsTable', 'mergeDomainStatus'];
const source = names.map(name => {
    const match = html.match(new RegExp(`        function ${name}\\([^]*?\\n        }`));
    assert.ok(match, `Dashboard function ${name} exists`);
    return match[0];
}).join('\n');

function dashboard() {
    const elements = Object.fromEntries(['domainTable', 'hostTable', 'domainsAttention', 'hostsAttention']
        .map(id => [id, { innerHTML: '', hidden: true }]));
    const context = vm.createContext({ document: { getElementById: id => elements[id] } });
    vm.runInContext(source, context);
    return { context, elements };
}

test('all inline dashboard scripts parse', () => {
    for (const match of html.matchAll(/<script\b[^>]*>([^]*?)<\/script>/g)) {
        new vm.Script(match[1]);
    }
});

test('a valid local certificate exposes SSH rejection on the default page', () => {
    const { context, elements } = dashboard();
    const hosts = [{ name: 'router', operational: 'MissingKey' }];
    const domains = context.mergeDomainStatus([{ name: 'jelly.example.com', host: 'router' }],
        [{ name: 'jelly.example.com', status: 'valid' }]);
    context.renderTable(domains, hosts);
    context.renderTabAttention(domains, hosts, true);
    context.renderHostsTable(hosts);
    assert.equal(elements.domainsAttention.hidden, false);
    assert.equal(elements.hostsAttention.hidden, false);
    assert.match(elements.domainTable.innerHTML, /status-badge valid/);
    assert.match(elements.domainTable.innerHTML, /status-badge host-status expired/);
    assert.match(elements.domainTable.innerHTML, /SSH authentication failed/);
    assert.match(elements.hostTable.innerHTML, /SSH authentication failed/);
});

test('failed deployment remains visible when SSH recovers and clears after retry', () => {
    const { context, elements } = dashboard();
    const hosts = [{ name: 'router', operational: 'Ready' }];
    const config = [{ name: 'jelly.example.com', host: 'router' }];
    for (const pending of [true, false]) {
        const domains = context.mergeDomainStatus(config,
            [{ name: 'jelly.example.com', status: 'valid', deploy_pending: pending }]);
        context.renderTable(domains, hosts);
        context.renderTabAttention(domains, hosts, true);
        assert.equal(elements.domainsAttention.hidden, !pending);
        assert.equal(elements.hostsAttention.hidden, true);
        assert.match(elements.domainTable.innerHTML, pending ? /Deployment pending/ : /Host ready/);
        assert.doesNotMatch(elements.domainTable.innerHTML, />Deployed</);
    }
});

test('unreachable, misconfigured, and unknown hosts mark the Hosts tab', () => {
    const { context, elements } = dashboard();
    for (const operational of ['Unreachable', 'NoDest', 'Error', undefined]) {
        const hosts = [{ name: 'router', operational }];
        context.renderTabAttention([], hosts, true);
        assert.equal(elements.hostsAttention.hidden, false, String(operational));
        assert.equal(elements.domainsAttention.hidden, true);
        assert.notEqual(context.hostHealth(hosts[0])[0], 'valid');
    }
    context.renderTabAttention([{ name: 'example.com', host: 'missing', status: 'valid' }], [], true);
    assert.equal(elements.domainsAttention.hidden, false);
    assert.equal(elements.hostsAttention.hidden, true);
});

test('missing status data cannot produce an all-clear dashboard', () => {
    const { context, elements } = dashboard();
    context.renderTabAttention([], [{ name: 'router', operational: 'Ready' }], false);
    assert.equal(elements.domainsAttention.hidden, false);
    assert.equal(elements.hostsAttention.hidden, true);
    context.renderTabAttention([], [], false, false);
    assert.equal(elements.domainsAttention.hidden, false);
    assert.equal(elements.hostsAttention.hidden, false);
});

test('certificate problems mark only Domains when the host is ready', () => {
    const { context, elements } = dashboard();
    const hosts = [{ name: 'router', operational: 'Ready' }];
    for (const status of ['expired', 'unknown', undefined]) {
        context.renderTabAttention([{ name: 'example.com', host: 'router', status }], hosts, true);
        assert.equal(elements.domainsAttention.hidden, false);
        assert.equal(elements.hostsAttention.hidden, true);
    }
});

test('healthy data clears both tab indicators', () => {
    const { context, elements } = dashboard();
    context.renderTabAttention([], [], false, false);
    context.renderTabAttention([{ name: 'example.com', host: 'router', status: 'valid' }],
        [{ name: 'router', operational: 'Ready' }], true);
    assert.equal(elements.domainsAttention.hidden, true);
    assert.equal(elements.hostsAttention.hidden, true);
    assert.doesNotMatch(html, /deploymentAlert|deployment-alert/);
});

test('diagnostic rows escape configured host and domain names', () => {
    const { context, elements } = dashboard();
    context.renderTable([{ name: '<img src=x onerror=alert(1)>', host: '<script>alert(1)</script>' }]);
    assert.doesNotMatch(elements.domainTable.innerHTML, /<script>|<img/);
    assert.match(elements.domainTable.innerHTML, /&lt;script&gt;/);
});
