'use strict';

// Base path derived from the URL so API calls work under any context path (e.g. /labbuilder).
const API_BASE = window.location.pathname.replace(/\/$/, '');

/* ── State ─────────────────────────────────────────────────────────────── */
const App = {
  currentEnvId: null,
  refreshTimer: null,
  genRefreshTimer: null,
  serverIP: localStorage.getItem('serverIP') || 'localhost',
};

/* ── Bootstrap & routing ─────────────────────────────────────────────── */
$(function () {
  // Restore saved server IP into navbar input
  if (App.serverIP !== 'localhost') $('#nav-server-ip').val(App.serverIP);

  // Persist changes; broadcast to any open export input in the current tab
  $('#nav-server-ip').on('input', function () {
    App.serverIP = $(this).val().trim() || 'localhost';
    localStorage.setItem('serverIP', App.serverIP === 'localhost' ? '' : App.serverIP);
    // Keep the export IP input in sync if it's currently rendered
    const exportVal = App.serverIP === 'localhost' ? '' : App.serverIP;
    $('#export-server-ip').val(exportVal);
  });

  $(window).on('hashchange', () => navigate(location.hash));
  navigate(location.hash);
});

function navigate(hash) {
  clearTimers();
  if (!hash || hash === '#' || hash === '#/') {
    App.currentEnvId = null;
    showHome();
  } else if (hash.startsWith('#/env/')) {
    App.currentEnvId = decodeURIComponent(hash.slice(6));
    showEnvDetail(App.currentEnvId);
  } else if (hash.startsWith('#/gcp-env/')) {
    App.currentEnvId = decodeURIComponent(hash.slice(10));
    showGCPEnvDetail(App.currentEnvId);
  } else if (hash.startsWith('#/az-env/')) {
    App.currentEnvId = decodeURIComponent(hash.slice(9));
    showAZEnvDetail(App.currentEnvId);
  } else {
    showHome();
  }
}

function clearTimers() {
  clearInterval(App.refreshTimer);
  clearInterval(App.genRefreshTimer);
  clearInterval(App.azGenTimer);
  App.refreshTimer = null;
  App.genRefreshTimer = null;
  App.azGenTimer = null;
  App.azPollFns = [];
}

/* ── Home page ──────────────────────────────────────────────────────── */
function showHome() {
  setBreadcrumb('');
  const tpl = document.getElementById('tpl-home').content.cloneNode(true);
  $('#main-content').empty().append(tpl);
  $('#btn-deploy').on('click', deployNewEnv);
  $('#btn-deploy-gcp').on('click', deployNewGCPEnv);
  $('#btn-deploy-az').on('click', deployNewAZEnv);
  loadEnvs();
  App.refreshTimer = setInterval(loadEnvs, 5000);
}

function loadEnvs() {
  $.getJSON(API_BASE + '/api/envs').done(renderEnvGrid).fail(() => renderEnvGrid([]));
}

function renderEnvGrid(envs) {
  const $grid = $('#env-grid').empty();
  if (!envs || envs.length === 0) {
    $grid.append(`
      <div class="col">
        <div class="card text-center py-5 border-dashed">
          <i class="bi bi-cloud-slash fs-1 text-secondary opacity-40"></i>
          <p class="mt-2 text-secondary">No environments running.<br>
            <a href="#" id="link-deploy">Deploy one to get started.</a></p>
        </div>
      </div>`);
    $('#link-deploy').on('click', e => { e.preventDefault(); deployNewEnv(); });
    return;
  }
  envs.forEach(env => {
    const isGCP   = env.cloud === 'gcp';
    const isAzure = env.cloud === 'azure';
    const tpl = document.getElementById('tpl-env-card').content.cloneNode(true);
    const $card = $(tpl).find('.card');
    $card.attr('data-env-id', env.id);
    const cloudBadge = isGCP
      ? '<span class="badge bg-warning text-dark me-1" style="font-size:.65em"><i class="bi bi-google"></i> GCP</span>'
      : isAzure
        ? '<span class="badge bg-info text-dark me-1" style="font-size:.65em"><i class="bi bi-microsoft"></i> Azure</span>'
        : '<span class="badge bg-info text-dark me-1" style="font-size:.65em">AWS</span>';
    $card.find('.env-name').html(cloudBadge + esc(labelForEnv(env)));
    $card.find('.env-port').text(env.flociPort || '—');
    $card.find('.env-account').text(env.accountId || '—');
    $card.find('.env-rds-range').text(env.rdsPortRange || '—');
    const $badge = $card.find('.env-status-badge');
    $badge.text(env.status).addClass(statusBadgeClass(env.status));
    const envHash = isGCP
      ? '#/gcp-env/' + encodeURIComponent(env.id)
      : isAzure
        ? '#/az-env/' + encodeURIComponent(env.id)
        : '#/env/' + encodeURIComponent(env.id);
    $card.find('.btn-open').on('click', () => { window.location.hash = envHash; });
    $card.find('.btn-destroy').on('click', e => {
      e.stopPropagation();
      if (isGCP) destroyGCPEnv(env);
      else if (isAzure) destroyAZEnv(env);
      else destroyEnv(env);
    });
    $card.on('click', function (e) {
      if (!$(e.target).is('button, a')) window.location.hash = envHash;
    });
    const $col = $('<div class="col">').append($card);
    $grid.append($col);
  });
}

function deployNewEnv() {
  if (!confirm('Deploy a new AWS environment?\nThis will start floci-aws and supporting containers.')) return;
  const $btn = $('#btn-deploy').prop('disabled', true)
    .html('<span class="spinner-border spinner-border-sm me-1"></span>Deploying…');
  $.post(API_BASE + '/api/envs')
    .done(res => {
      $btn.prop('disabled', false).html('<i class="bi bi-plus-circle me-1"></i>Deploy New Env');
      openJobModal('Deploying New Environment', res.jobId, () => loadEnvs());
    })
    .fail(xhr => {
      $btn.prop('disabled', false).html('<i class="bi bi-plus-circle me-1"></i>Deploy New Env');
      showToast('Deploy failed: ' + apiError(xhr), 'danger');
    });
}

function deployNewGCPEnv() {
  if (!confirm('Deploy a new GCP environment?\nThis will start floci-gcp and supporting containers.')) return;
  const $btn = $('#btn-deploy-gcp').prop('disabled', true)
    .html('<span class="spinner-border spinner-border-sm me-1"></span>Deploying…');
  $.post(API_BASE + '/api/gcp-envs')
    .done(res => {
      $btn.prop('disabled', false).html('<i class="bi bi-google me-1"></i>Deploy GCP Env');
      openJobModal('Deploying New GCP Environment', res.jobId, () => loadEnvs());
    })
    .fail(xhr => {
      $btn.prop('disabled', false).html('<i class="bi bi-google me-1"></i>Deploy GCP Env');
      showToast('GCP Deploy failed: ' + apiError(xhr), 'danger');
    });
}

function destroyGCPEnv(env) {
  if (!confirm(`Destroy ${labelForEnv(env)}?\nThis will stop all containers and remove all data. This cannot be undone.`)) return;
  $.ajax({ url: API_BASE + '/api/gcp-envs/' + encodeURIComponent(env.id), method: 'DELETE' })
    .done(res => openJobModal('Destroying ' + labelForEnv(env), res.jobId, () => loadEnvs()))
    .fail(xhr => showToast('Destroy failed: ' + apiError(xhr), 'danger'));
}

function destroyEnv(env) {
  if (!confirm(`Destroy ${labelForEnv(env)}?\nThis will stop all containers and remove all data. This cannot be undone.`)) return;
  $.ajax({ url: API_BASE + '/api/envs/' + encodeURIComponent(env.id), method: 'DELETE' })
    .done(res => openJobModal('Destroying ' + labelForEnv(env), res.jobId, () => loadEnvs()))
    .fail(xhr => showToast('Destroy failed: ' + apiError(xhr), 'danger'));
}

/* ── GCP Env Detail page ────────────────────────────────────────────── */
function showGCPEnvDetail(envId) {
  setBreadcrumb(envId);
  const tpl = document.getElementById('tpl-gcp-env-detail').content.cloneNode(true);
  $('#main-content').empty().append(tpl);
  $('#main-content a[href="#"]').first().on('click', e => {
    e.preventDefault();
    window.location.hash = '#';
  });
  $('#gcp-detail-tabs').on('click', 'a.nav-link', function (e) {
    e.preventDefault();
    $('#gcp-detail-tabs a.nav-link').removeClass('active');
    $(this).addClass('active');
    loadGCPTab($(this).data('gcpTab'), envId);
  });
  loadGCPEnvHeader(envId);
  loadGCPTab('cloudsql', envId);
  App.refreshTimer = setInterval(() => {
    if ($('[data-gcp-tab="cloudsql"]').hasClass('active') || !$('#gcp-detail-tabs .nav-link.active').length) {
      refreshCloudSQLResources(envId);
    }
  }, 8000);
}

function loadGCPEnvHeader(envId) {
  $.getJSON(API_BASE + '/api/gcp-envs/' + encodeURIComponent(envId)).done(d => {
    $('#gcp-detail-title').text(labelForEnv(d));
    $('#gcp-detail-status').text(d.status).removeClass().addClass('badge ' + statusBadgeClass(d.status));
    $('#gcp-detail-port').text(d.flociPort || '—');
    $('#gcp-detail-project').text(d.accountId || '—');
    $('#gcp-detail-network').text(d.network || '—');
  });
}

function loadGCPTab(tab, envId) {
  const $content = $('#gcp-detail-tab-content');
  const tplId = tab === 'cloudsql' ? 'tpl-tab-cloudsql'
              : tab === 'gcp-generator' ? 'tpl-tab-gcp-generator'
              : 'tpl-tab-create-cloudsql';
  const tpl = document.getElementById(tplId);
  if (!tpl) return;
  if (App.gcpGenTimer) { clearInterval(App.gcpGenTimer); App.gcpGenTimer = null; }
  $content.empty().append(tpl.content.cloneNode(true));
  switch (tab) {
    case 'cloudsql':        initTabCloudSQL(envId); break;
    case 'create-cloudsql': initTabCreateCloudSQL(envId); break;
    case 'gcp-generator':   initTabGCPGenerator(envId); break;
  }
}

/* ── Cloud SQL resources tab ────────────────────────────────────────── */
function initTabCloudSQL(envId) {
  refreshCloudSQLResources(envId);
  $('#btn-refresh-gcp-detail').on('click', () => refreshCloudSQLResources(envId));

  $('#gcp-export-server-ip').val(App.serverIP === 'localhost' ? '' : App.serverIP);
  $('#gcp-export-server-ip').on('input', function () {
    App.serverIP = $(this).val().trim() || 'localhost';
    localStorage.setItem('serverIP', App.serverIP === 'localhost' ? '' : App.serverIP);
    $('#nav-server-ip').val(App.serverIP === 'localhost' ? '' : App.serverIP);
  });

  const lsGwKey = 'export-gw-' + envId;
  const savedGw = localStorage.getItem(lsGwKey) || '';
  if (savedGw) $('#gcp-export-gateway-name').val(savedGw);
  $('#gcp-export-gateway-name').on('input', function () {
    localStorage.setItem(lsGwKey, $(this).val());
  });

  $('#btn-export-gcp-assets').on('click', function () {
    const serverIP    = encodeURIComponent($('#gcp-export-server-ip').val().trim());
    const gatewayName = encodeURIComponent($('#gcp-export-gateway-name').val().trim());
    const url = `${API_BASE}/api/gcp-envs/${encodeURIComponent(envId)}/export?serverIP=${serverIP}&gatewayName=${gatewayName}`;
    const $a = $('<a>').attr({ href: url, download: '' }).appendTo('body');
    $a[0].click();
    $a.remove();
  });
}

function refreshCloudSQLResources(envId) {
  $.getJSON(API_BASE + '/api/gcp-envs/' + encodeURIComponent(envId)).done(d => {
    renderCloudSQLTable(d.cloudSQL || [], envId);
  });
}

function renderCloudSQLTable(rows, envId) {
  const $tbody = $('#cloudsql-tbody').empty();
  if (!rows.length) {
    $tbody.append('<tr><td colspan="5" class="text-center text-secondary p-3">No Cloud SQL instances — create one in the Create Cloud SQL tab</td></tr>');
    return;
  }
  rows.forEach(r => {
    const eng = r.engine || '—';
    $tbody.append(`<tr>
      <td class="font-monospace small">${esc(r.id)}</td>
      <td><span class="badge bg-warning text-dark">${esc(eng)}</span></td>
      <td><span class="badge ${r.status === 'RUNNABLE' ? 'bg-success' : 'bg-secondary'}">${esc(r.status)}</span></td>
      <td class="font-monospace small">${esc(r.endpoint)}</td>
      <td class="text-center">
        <button class="btn btn-sm btn-outline-info btn-cloudsql-info me-1"
                data-instance="${esc(r.id)}"
                title="Show full Cloud SQL instance info: Pub/Sub, credentials, DSF onboarding details">
          <i class="bi bi-info-circle"></i>
        </button>
        <button class="btn btn-sm btn-outline-secondary btn-test-cloudsql"
                data-engine="${esc(eng)}" data-instance="${esc(r.id)}"
                title="Run Pub/Sub audit log test against this Cloud SQL instance and stream output">
          <i class="bi bi-play-fill"></i>
        </button>
      </td>
    </tr>`);
  });
  $tbody.find('.btn-cloudsql-info').on('click', function () {
    showCloudSQLDetail(envId, $(this).data('instance'));
  });
  $tbody.find('.btn-test-cloudsql').on('click', function () {
    const eng = $(this).data('engine');
    const inst = $(this).data('instance');
    $.ajax({
      url: `${API_BASE}/api/gcp-envs/${encodeURIComponent(envId)}/test/cloudsql/${eng}`,
      method: 'POST',
      contentType: 'application/json',
      data: JSON.stringify({ instanceId: inst }),
    })
      .done(res => openJobModal(`Test Cloud SQL — ${inst}`, res.jobId))
      .fail(xhr => showToast(apiError(xhr), 'danger'));
  });
}

function showCloudSQLDetail(envId, instanceId) {
  document.getElementById('cloudSQLOffcanvasTitle').textContent = instanceId;
  document.getElementById('cloudSQLOffcanvasBody').innerHTML =
    '<div class="d-flex justify-content-center p-5"><div class="spinner-border spinner-border-sm text-info"></div></div>';

  const oc = new bootstrap.Offcanvas(document.getElementById('cloudSQLOffcanvas'));
  oc.show();

  $.getJSON(`${API_BASE}/api/gcp-envs/${encodeURIComponent(envId)}/cloudsql/detail?instance=${encodeURIComponent(instanceId)}`)
    .done(d => renderCloudSQLDetailPanel(d))
    .fail(xhr => {
      document.getElementById('cloudSQLOffcanvasBody').innerHTML =
        `<div class="p-3 text-danger">${esc(apiError(xhr))}</div>`;
    });
}

function renderCloudSQLDetailPanel(d) {
  const endpointDisplay = d.endpoint && d.endpoint !== ':0'
    ? d.endpoint.replace('localhost', App.serverIP)
    : '(starting…)';
  const rows = [
    ['Instance ID',      d.id],
    ['Engine',           `${d.engine} (${d.engineVersion || ''})`.replace(' ()', '')],
    ['Status',           d.status],
    ['Project ID',       d.projectId],
    ['Region',           d.region],
    ['Endpoint',         endpointDisplay],
    d.proxyPort ? ['DBeaver / Host Access', `${(d.proxyHost||'localhost').replace('localhost', App.serverIP)}:${d.proxyPort}`] : null,
    ['Master User',      d.masterUser],
    ['Master Password',  d.masterPass],
    ['Audit User',       d.auditUser],
    ['Audit Password',   d.auditPass],
    null,
    ['Pub/Sub Topic',       d.topicName],
    ['Pub/Sub Subscription', d.subscriptionId],
    ['Log Sink Name',       d.logSinkName],
    ['Service Account',     d.serviceAccount],
    ['Floci Endpoint URL',  (d.flociEndpoint || '').replace('localhost', App.serverIP)],
  ];

  let html = '<div class="alert alert-info mx-3 mt-3 small py-2">' +
    '<i class="bi bi-info-circle me-1"></i>' +
    '<strong>DSF Hub onboarding:</strong> Use the Pub/Sub Subscription as the log aggregator asset. ' +
    'Auth: Service Account key (from setup output).</div>';
  html += '<table class="table table-sm fam-info-table mb-0">';
  rows.forEach(row => {
    if (row === null) {
      html += '<tr><td colspan="2" class="p-0"><hr class="my-1 border-secondary"></td></tr>';
      return;
    }
    const [k, v] = row;
    const copyable = v && !v.startsWith('(');
    const btn = copyable
      ? `<button class="btn btn-sm btn-link p-0 ms-1 text-secondary copy-btn"
                 data-val="${esc(v)}" title="Copy to clipboard">
           <i class="bi bi-clipboard"></i>
         </button>`
      : '';
    html += `<tr><th class="text-nowrap">${esc(k)}</th>
                 <td class="font-monospace small text-break">${esc(v || '—')}${btn}</td></tr>`;
  });
  html += '</table>';

  const $body = $('#cloudSQLOffcanvasBody').html(html);
  $body.on('click', '.copy-btn', function () {
    navigator.clipboard.writeText($(this).data('val'));
    $(this).html('<i class="bi bi-check-lg text-success"></i>').attr('title', 'Copied!');
    setTimeout(() => $(this).html('<i class="bi bi-clipboard"></i>').attr('title', 'Copy to clipboard'), 1500);
  });
}

/* ── Create Cloud SQL tab ───────────────────────────────────────────── */
function initTabCreateCloudSQL(envId) {
  $('#btn-create-cloudsql').on('click', function () {
    const engine = $('#cloudsql-engine').val();
    doCreateCloudSQL(envId, engine, '');
  });
  $('#btn-cloudsql-info').on('click', function () {
    const engine = $('#cloudsql-engine').val();
    $.getJSON(API_BASE + '/api/gcp-envs/' + encodeURIComponent(envId)).done(d => {
      const endpoint = (d.flociPort ? `http://localhost:${d.flociPort}` : 'http://localhost:4589').replace('localhost', App.serverIP);
      const projectId = d.accountId || 'floci-gcp-lab-1';
      const slot = d.slot || 1;
      const instanceId = `my${engine}-gcp${slot}-dsf`;
      showCmdInfo(
        (engine === 'postgres' ? 'PostgreSQL' : 'MySQL') + ' Cloud SQL Setup — curl commands',
        getCmdStepsCloudSQL(engine, instanceId, endpoint, projectId)
      );
    });
  });
}

function doCreateCloudSQL(envId, engine, instanceId) {
  $('#btn-create-cloudsql').prop('disabled', true);
  $.ajax({
    url: `${API_BASE}/api/gcp-envs/${encodeURIComponent(envId)}/cloudsql`,
    method: 'POST',
    contentType: 'application/json',
    data: JSON.stringify({ engine, instanceId }),
  })
    .done(res => {
      $('#btn-create-cloudsql').prop('disabled', false);
      openJobModal(`Create Cloud SQL (${engine}) — ${res.instanceId}`, res.jobId,
        () => loadGCPTab('cloudsql', envId));
    })
    .fail(xhr => {
      $('#btn-create-cloudsql').prop('disabled', false);
      if (xhr.status === 409) {
        const data = JSON.parse(xhr.responseText);
        showCloudSQLConfirm(envId, engine, data.existing || [], data.suggested || '');
      } else {
        showToast(apiError(xhr), 'danger');
      }
    });
}

function showCloudSQLConfirm(envId, engine, existing, suggested) {
  const existingList = existing.map(id => `<li class="font-monospace small">${esc(id)}</li>`).join('');
  $('#rdsConfirmBody').html(`
    <p>A <strong>${esc(engine)}</strong> Cloud SQL instance already exists in this environment:</p>
    <ul class="mb-3">${existingList}</ul>
    <p class="mb-0 text-secondary small">
      <strong>Overwrite</strong> re-runs setup on the existing instance (idempotent).<br>
      <strong>Create New</strong> provisions a separate instance: <code>${esc(suggested)}</code>
    </p>`);

  const modal = new bootstrap.Modal(document.getElementById('rdsConfirmModal'));
  modal.show();
  $('#btn-rds-overwrite').off('click').on('click', () => {
    modal.hide();
    doCreateCloudSQL(envId, engine, existing[existing.length - 1]);
  });
  $('#btn-rds-create-new').off('click').on('click', () => {
    modal.hide();
    doCreateCloudSQL(envId, engine, suggested);
  });
}

function getCmdStepsCloudSQL(engine, instanceId, endpoint, projectId) {
  const topicName = instanceId + '-audit-topic';
  const subName   = instanceId + '-dsf-sub';
  const dbVersion = engine === 'postgres' ? 'POSTGRES_16' : 'MYSQL_8_0';

  return [
    {
      title: 'Create Cloud SQL instance',
      note:  'REST POST to the Cloud SQL Admin API. floci-gcp provisions a Docker container with the database.',
      cmd:
        `curl -s -X POST ${endpoint}/sql/v1beta4/projects/${projectId}/instances \\\n` +
        `  -H 'Content-Type: application/json' \\\n` +
        `  -d '{"name":"${instanceId}","databaseVersion":"${dbVersion}","region":"us-central1","rootPassword":"secret123"}'`,
    },
    {
      title: 'Wait for RUNNABLE state',
      note:  'Poll until the instance state transitions from PENDING to RUNNABLE.',
      cmd:
        `curl -s ${endpoint}/sql/v1beta4/projects/${projectId}/instances/${instanceId} \\\n` +
        `  | grep -o '"state":"[^"]*"'`,
    },
    {
      title: 'Create Pub/Sub topic',
      note:  'DSF Agentless Gateway subscribes to this topic to receive audit log entries.',
      cmd:
        `curl -s -X PUT ${endpoint}/v1/projects/${projectId}/topics/${topicName} \\\n` +
        `  -H 'Content-Type: application/json' -d '{}'`,
    },
    {
      title: 'Create Pub/Sub subscription',
      note:  'DSF uses pull-mode subscription to read batches of log entries.',
      cmd:
        `curl -s -X PUT ${endpoint}/v1/projects/${projectId}/subscriptions/${subName} \\\n` +
        `  -H 'Content-Type: application/json' \\\n` +
        `  -d '{"topic":"projects/${projectId}/topics/${topicName}","ackDeadlineSeconds":60}'`,
    },
    {
      title: 'Create Cloud Logging sink → Pub/Sub',
      note:  'The Log Router sink routes cloudsql_database audit logs to the Pub/Sub topic.',
      cmd:
        `curl -s -X POST ${endpoint}/v2/projects/${projectId}/sinks \\\n` +
        `  -H 'Content-Type: application/json' \\\n` +
        `  -d '{"name":"dsf-cloudsql-sink","destination":"pubsub.googleapis.com/projects/${projectId}/topics/${topicName}","filter":"resource.type=\\"cloudsql_database\\""}'`,
    },
    {
      title: 'Create IAM service account + key',
      note:  'DSF Gateway authenticates to Pub/Sub using a service account key file.',
      cmd:
        `curl -s -X POST ${endpoint}/v1/projects/${projectId}/serviceAccounts \\\n` +
        `  -H 'Content-Type: application/json' \\\n` +
        `  -d '{"accountId":"dsf-gateway","serviceAccount":{"displayName":"DSF Gateway"}}'\n\n` +
        `curl -s -X POST ${endpoint}/v1/projects/${projectId}/serviceAccounts/dsf-gateway@${projectId}.iam.gserviceaccount.com/keys \\\n` +
        `  -H 'Content-Type: application/json' -d '{"privateKeyType":"TYPE_GOOGLE_CREDENTIALS_FILE"}'`,
    },
  ];
}

/* ── GCP Data Generator tab ─────────────────────────────────────────── */
function initTabGCPGenerator(envId) {
  loadCloudSQLGenSection(envId);
  App.gcpGenTimer = setInterval(() => refreshAllCloudSQLGenCards(envId), 3000);
}

function loadCloudSQLGenSection(envId) {
  $.getJSON(`${API_BASE}/api/gcp-envs/${encodeURIComponent(envId)}`).done(d => {
    const $body = $('#cloudsql-gen-body').empty();
    const instances = d.cloudSQL || [];
    if (!instances.length) {
      $body.html('<p class="text-secondary small">No Cloud SQL instances found. Create one in the Create Cloud SQL tab first.</p>');
      return;
    }
    instances.forEach(inst => renderCloudSQLGenCard(envId, inst, $body));
  });
}

function renderCloudSQLGenCard(envId, inst, $container) {
  const $card = $(`
    <div class="border rounded p-3 mb-3 cloudsql-gen-card" data-instance="${esc(inst.id)}">
      <div class="d-flex align-items-center gap-2 mb-2">
        <span class="fw-bold small font-monospace">${esc(inst.id)}</span>
        <span class="badge bg-warning text-dark">${esc(inst.engine)}</span>
        <span class="badge bg-secondary cloudsql-gen-badge ms-auto">Stopped</span>
      </div>
      <p class="text-secondary small mb-2">
        Generates continuous SQL traffic: INSERT/SELECT/UPDATE/DELETE + permission violations + login failures for DSF audit log testing.
      </p>
      <div class="d-flex gap-2 mb-2">
        <button class="btn btn-success btn-sm btn-csql-start">
          <i class="bi bi-play-fill me-1"></i>Start Generator
        </button>
        <button class="btn btn-danger btn-sm btn-csql-stop" disabled>
          <i class="bi bi-stop-fill me-1"></i>Stop
        </button>
        <button class="btn btn-outline-secondary btn-sm ms-auto btn-csql-refresh">
          <i class="bi bi-arrow-clockwise"></i>
        </button>
      </div>
      <div class="cloudsql-gen-stats small text-muted mb-1 d-none"></div>
      <pre class="job-output gen-log cloudsql-gen-log p-2 m-0 d-none" style="max-height:200px"></pre>
    </div>`);

  $card.find('.btn-csql-start').on('click', function () {
    $(this).prop('disabled', true);
    $.post(`${API_BASE}/api/gcp-envs/${encodeURIComponent(envId)}/generator/cloudsql/start`,
      JSON.stringify({ instanceId: inst.id }), null, 'json')
      .done(() => { showToast('Generator started for ' + inst.id, 'success'); refreshCloudSQLGenCard(envId, inst.id, $card); })
      .fail(xhr => { $(this).prop('disabled', false); showToast(apiError(xhr), 'danger'); });
  });
  $card.find('.btn-csql-stop').on('click', function () {
    $.post(`${API_BASE}/api/gcp-envs/${encodeURIComponent(envId)}/generator/cloudsql/stop`,
      JSON.stringify({ instanceId: inst.id }), null, 'json')
      .done(() => { showToast('Generator stopped', 'warning'); refreshCloudSQLGenCard(envId, inst.id, $card); })
      .fail(xhr => showToast(apiError(xhr), 'danger'));
  });
  $card.find('.btn-csql-refresh').on('click', () => refreshCloudSQLGenCard(envId, inst.id, $card));

  $container.append($card);
  refreshCloudSQLGenCard(envId, inst.id, $card);
}

function refreshCloudSQLGenCard(envId, instanceId, $card) {
  $.getJSON(`${API_BASE}/api/gcp-envs/${encodeURIComponent(envId)}/generator/cloudsql/logs?instance=${encodeURIComponent(instanceId)}`)
    .done(res => {
      const $badge = $card.find('.cloudsql-gen-badge');
      const $log   = $card.find('.cloudsql-gen-log');
      const $stats = $card.find('.cloudsql-gen-stats');
      const $start = $card.find('.btn-csql-start');
      const $stop  = $card.find('.btn-csql-stop');

      if (res.running) {
        $badge.text('Running').removeClass('bg-secondary').addClass('bg-success');
        $start.prop('disabled', true);
        $stop.prop('disabled', false);
      } else {
        $badge.text('Stopped').removeClass('bg-success').addClass('bg-secondary');
        $start.prop('disabled', false);
        $stop.prop('disabled', true);
      }
      if (res.lines && res.lines.length) {
        $log.removeClass('d-none').text(res.lines.join('\n'));
        $log[0].scrollTop = $log[0].scrollHeight;
      }
      if (res.stats && res.stats.total > 0) {
        const s = res.stats;
        $stats.removeClass('d-none').html(
          `total: <b>${s.total}</b> &nbsp;|&nbsp; ` +
          `<span class="text-success">ok: ${s.success}</span> &nbsp;` +
          `<span class="text-danger">err: ${s.errors}</span> &nbsp;|&nbsp; ` +
          `ins: ${s.inserts} sel: ${s.selects} upd: ${s.updates} del: ${s.deletes} &nbsp;|&nbsp; ` +
          `<span class="text-warning">perm_denied: ${s.permDenied}</span> ` +
          `grants: ${s.grants} revokes: ${s.revokes} &nbsp;|&nbsp; ` +
          `login_fail: ${s.loginFails} sql_err: ${s.sqlErrors}`
        );
      }
    });
}

function refreshAllCloudSQLGenCards(envId) {
  $('.cloudsql-gen-card').each(function () {
    const instanceId = $(this).data('instance');
    if (instanceId) refreshCloudSQLGenCard(envId, instanceId, $(this));
  });
}

/* ── Env Detail page ────────────────────────────────────────────────── */
function showEnvDetail(envId) {
  setBreadcrumb(envId);
  const tpl = document.getElementById('tpl-env-detail').content.cloneNode(true);
  $('#main-content').empty().append(tpl);
  $('#main-content a[href="#"]').first().on('click', e => {
    e.preventDefault();
    window.location.hash = '#';
  });
  $('#detail-tabs').on('click', 'a.nav-link', function (e) {
    e.preventDefault();
    $('#detail-tabs a.nav-link').removeClass('active');
    $(this).addClass('active');
    loadTab($(this).data('tab'), envId);
  });
  loadEnvHeader(envId);
  loadTab('resources', envId);
  App.refreshTimer = setInterval(() => {
    if ($('[data-tab="resources"]').hasClass('active') || !$('.nav-link.active').length) {
      refreshResources(envId);
    }
  }, 8000);
}

function loadEnvHeader(envId) {
  $.getJSON(API_BASE + '/api/envs/' + encodeURIComponent(envId)).done(d => {
    $('#detail-title').text(labelForEnv(d));
    $('#detail-status').text(d.status).removeClass().addClass('badge ' + statusBadgeClass(d.status));
    $('#detail-port').text(d.flociPort || '—');
    $('#detail-account').text(d.accountId || '—');
    $('#detail-network').text(d.network || '—');
  });
}

function loadTab(tab, envId) {
  const $content = $('#detail-tab-content');
  const tpl = document.getElementById('tpl-tab-' + tab);
  if (!tpl) return;
  $content.empty().append(tpl.content.cloneNode(true));
  switch (tab) {
    case 'resources':   initTabResources(envId); break;
    case 'create-rds':  initTabCreateRDS(envId);  break;
    case 'fam':         initTabFAM(envId);         break;
    case 'generator':   initTabGenerator(envId);   break;
  }
}

/* ── Resources tab ──────────────────────────────────────────────────── */
function initTabResources(envId) {
  refreshResources(envId);
  $('#btn-refresh-detail').on('click', () => refreshResources(envId));

  // Pre-fill server IP from global setting (kept in sync with navbar)
  $('#export-server-ip').val(App.serverIP === 'localhost' ? '' : App.serverIP);

  // Changes to the export IP update the global setting and the navbar input
  $('#export-server-ip').on('input', function () {
    App.serverIP = $(this).val().trim() || 'localhost';
    localStorage.setItem('serverIP', App.serverIP === 'localhost' ? '' : App.serverIP);
    const navVal = App.serverIP === 'localhost' ? '' : App.serverIP;
    $('#nav-server-ip').val(navVal);
  });

  // Persist gateway name per-env
  const lsGwKey = 'export-gw-' + envId;
  const savedGw = localStorage.getItem(lsGwKey) || '';
  if (savedGw) $('#export-gateway-name').val(savedGw);
  $('#export-gateway-name').on('input', function () {
    localStorage.setItem(lsGwKey, $(this).val());
  });

  // Download via hidden anchor
  $('#btn-export-assets').on('click', function () {
    const serverIP    = encodeURIComponent($('#export-server-ip').val().trim());
    const gatewayName = encodeURIComponent($('#export-gateway-name').val().trim());
    const url = `${API_BASE}/api/envs/${encodeURIComponent(envId)}/export?serverIP=${serverIP}&gatewayName=${gatewayName}`;
    const $a = $('<a>').attr({ href: url, download: '' }).appendTo('body');
    $a[0].click();
    $a.remove();
  });
}

function refreshResources(envId) {
  $.getJSON(API_BASE + '/api/envs/' + encodeURIComponent(envId)).done(d => {
    renderRDSTable(d.rds || [], envId);
    renderBucketList(d.buckets || []);
  });
}

function renderRDSTable(rows, envId) {
  const $tbody = $('#rds-tbody').empty();
  if (!rows.length) {
    $tbody.append('<tr><td colspan="5" class="text-center text-secondary p-3">No RDS instances — create one in the Create RDS tab</td></tr>');
    return;
  }
  rows.forEach(r => {
    const eng = r.engine || '—';
    const genBadge = r.generatorRunning
      ? '<span class="badge bg-success ms-1" title="Background SQL generator is running">Gen●</span>'
      : '';
    $tbody.append(`<tr>
      <td class="font-monospace small">${esc(r.id)}</td>
      <td><span class="badge bg-warning text-dark">${esc(eng)}</span>${genBadge}</td>
      <td><span class="badge ${r.status === 'available' ? 'bg-success' : 'bg-secondary'}">${esc(r.status)}</span></td>
      <td class="font-monospace small">${esc(r.endpoint)}</td>
      <td class="text-center">
        <button class="btn btn-sm btn-outline-info btn-rds-info me-1"
                data-instance="${esc(r.id)}"
                title="Show full RDS instance info: ARN, CloudWatch log group, credentials, parameter group">
          <i class="bi bi-info-circle"></i>
        </button>
        <button class="btn btn-sm btn-outline-secondary btn-test-rds"
                data-engine="${esc(eng)}" data-instance="${esc(r.id)}"
                title="Run CloudWatch audit log test against this RDS instance and stream output">
          <i class="bi bi-play-fill"></i>
        </button>
      </td>
    </tr>`);
  });
  $tbody.find('.btn-rds-info').on('click', function () {
    showRDSDetail(envId, $(this).data('instance'));
  });
  $tbody.find('.btn-test-rds').on('click', function () {
    const eng = $(this).data('engine');
    const inst = $(this).data('instance');
    $.ajax({
      url: `${API_BASE}/api/envs/${encodeURIComponent(envId)}/test/rds/${eng}`,
      method: 'POST',
      contentType: 'application/json',
      data: JSON.stringify({ instanceId: inst }),
    })
      .done(res => openJobModal(`Test RDS — ${inst}`, res.jobId))
      .fail(xhr => showToast(apiError(xhr), 'danger'));
  });
}

function renderBucketList(buckets) {
  const $list = $('#bucket-list').empty();
  if (!buckets.length) {
    $list.append('<li class="list-group-item text-secondary text-center">No buckets found</li>');
    return;
  }
  buckets.forEach(b => {
    $list.append(`<li class="list-group-item font-monospace small"><i class="bi bi-bucket me-2 text-info"></i>${esc(b)}</li>`);
  });
}

/* ── Create RDS tab ─────────────────────────────────────────────────── */
function initTabCreateRDS(envId) {
  $('#btn-create-rds').on('click', function () {
    const engine = $('#rds-engine').val();
    doCreateRDS(envId, engine, '');
  });
  $('#btn-rds-info').on('click', function () {
    const engine = $('#rds-engine').val();
    $.getJSON(API_BASE + '/api/envs/' + encodeURIComponent(envId)).done(d => {
      const rawEndpoint = d.flociEndpoint || ('http://localhost:' + d.flociPort);
      const endpoint = rawEndpoint.replace('localhost', App.serverIP);
      const suffix = d.slot || envId.replace('floci-', '');
      const instanceId = 'my' + engine + '-' + suffix + '-dsf';
      showCmdInfo(
        engine.charAt(0).toUpperCase() + engine.slice(1) + ' RDS Setup — AWS CLI commands',
        getCmdStepsRDS(engine, instanceId, endpoint)
      );
    });
  });
}

// doCreateRDS: if instanceId is empty the backend will check for conflicts (409).
function doCreateRDS(envId, engine, instanceId) {
  $('#btn-create-rds').prop('disabled', true);
  $.ajax({
    url: `${API_BASE}/api/envs/${encodeURIComponent(envId)}/rds`,
    method: 'POST',
    contentType: 'application/json',
    data: JSON.stringify({ engine, instanceId }),
  })
    .done(res => {
      $('#btn-create-rds').prop('disabled', false);
      openJobModal(`Create RDS (${engine}) — ${res.instanceId}`, res.jobId,
        () => loadTab('resources', envId));
    })
    .fail(xhr => {
      $('#btn-create-rds').prop('disabled', false);
      if (xhr.status === 409) {
        const data = JSON.parse(xhr.responseText);
        showRDSConfirm(envId, engine, data.existing || [], data.suggested || '');
      } else {
        showToast(apiError(xhr), 'danger');
      }
    });
}

function showRDSConfirm(envId, engine, existing, suggested) {
  const existingList = existing.map(id =>
    `<li class="font-monospace small">${esc(id)}</li>`).join('');
  $('#rdsConfirmBody').html(`
    <p>A <strong>${esc(engine)}</strong> instance already exists in this environment:</p>
    <ul class="mb-3">${existingList}</ul>
    <p class="mb-0 text-secondary small">
      <strong>Overwrite</strong> re-runs setup on the existing instance (idempotent).<br>
      <strong>Create New</strong> provisions a separate instance:
      <code>${esc(suggested)}</code>
    </p>`);

  const modal = new bootstrap.Modal(document.getElementById('rdsConfirmModal'));
  modal.show();

  $('#btn-rds-overwrite').off('click').on('click', () => {
    modal.hide();
    doCreateRDS(envId, engine, existing[existing.length - 1]);
  });
  $('#btn-rds-create-new').off('click').on('click', () => {
    modal.hide();
    doCreateRDS(envId, engine, suggested);
  });
}

/* ── RDS detail offcanvas ───────────────────────────────────────────── */
function showRDSDetail(envId, instanceId) {
  document.getElementById('rdsOffcanvasTitle').textContent = instanceId;
  document.getElementById('rdsOffcanvasBody').innerHTML =
    '<div class="d-flex justify-content-center p-5"><div class="spinner-border spinner-border-sm text-info"></div></div>';

  const oc = new bootstrap.Offcanvas(document.getElementById('rdsOffcanvas'));
  oc.show();

  $.getJSON(`${API_BASE}/api/envs/${encodeURIComponent(envId)}/rds/detail?instance=${encodeURIComponent(instanceId)}`)
    .done(d => renderRDSDetailPanel(d))
    .fail(xhr => {
      document.getElementById('rdsOffcanvasBody').innerHTML =
        `<div class="p-3 text-danger">${esc(apiError(xhr))}</div>`;
    });
}

function renderRDSDetailPanel(d) {
  const rows = [
    ['Instance ID',           d.id],
    ['Engine',                `${d.engine} ${d.engineVersion || ''}`.trim()],
    ['Status',                d.status],
    ['Endpoint (host:port)',  d.endpoint],
    ['Master User',           d.masterUser],
    ['Master Password',       d.masterPass],
    ['Audit Mgr User',        d.auditMgrUser],
    ['Audit Mgr Password',    d.auditMgrPass],
    ['Default DB',            d.dbName],
    ['Instance Class',        d.instanceClass],
    ['Parameter Group',       d.paramGroup],
    null, // separator
    ['RDS ARN',               d.arn],
    ['CloudWatch Log Group',  d.cloudWatchLogGroup],
    ['CloudWatch Log ARN',    d.cloudWatchArn],
    ['Floci Endpoint URL',    d.flociEndpoint],
  ];

  let html = '<table class="table table-sm fam-info-table mb-0">';
  rows.forEach(row => {
    if (row === null) {
      html += '<tr><td colspan="2" class="p-0"><hr class="my-1 border-secondary"></td></tr>';
      return;
    }
    const [k, v] = row;
    const copyable = v && !v.startsWith('(');
    const btn = copyable
      ? `<button class="btn btn-sm btn-link p-0 ms-1 text-secondary copy-btn"
                 data-val="${esc(v)}" title="Copy to clipboard">
           <i class="bi bi-clipboard"></i>
         </button>`
      : '';
    html += `<tr><th class="text-nowrap">${esc(k)}</th>
                 <td class="font-monospace small text-break">${esc(v || '—')}${btn}</td></tr>`;
  });
  html += '</table>';

  const $body = $('#rdsOffcanvasBody').html(html);
  $body.on('click', '.copy-btn', function () {
    navigator.clipboard.writeText($(this).data('val'));
    $(this).html('<i class="bi bi-check-lg text-success"></i>').attr('title', 'Copied!');
    setTimeout(() => $(this).html('<i class="bi bi-clipboard"></i>').attr('title', 'Copy to clipboard'), 1500);
  });
}

/* ── FAM tab ────────────────────────────────────────────────────────── */
function initTabFAM(envId) {
  $.getJSON(API_BASE + '/api/envs/' + encodeURIComponent(envId)).done(d => {
    if (d.fam) renderFAMInfo(d.fam);
    renderFAMWarningPanel(d.flociPort || 0);
  });
  $('#btn-fam-info').on('click', function () {
    $.getJSON(API_BASE + '/api/envs/' + encodeURIComponent(envId)).done(d => {
      const rawEndpoint = d.flociEndpoint || ('http://localhost:' + d.flociPort);
      const endpoint = rawEndpoint.replace('localhost', App.serverIP);
      const suffix = d.slot || envId.replace('floci-', '');
      showCmdInfo('FAM / S3 Setup — AWS CLI commands', getCmdStepsFAM(suffix, endpoint));
    });
  });
  $('#btn-create-fam').on('click', function () {
    $(this).prop('disabled', true);
    const self = this;
    $.post(`${API_BASE}/api/envs/${encodeURIComponent(envId)}/fam`)
      .done(res => {
        $(self).prop('disabled', false);
        openJobModal('Setup FAM Resources', res.jobId, () => {
          $.getJSON(API_BASE + '/api/envs/' + encodeURIComponent(envId)).done(d => {
            if (d.fam) renderFAMInfo(d.fam);
            renderFAMWarningPanel(d.flociPort || 0);
          });
        });
      })
      .fail(xhr => { $(self).prop('disabled', false); showToast(apiError(xhr), 'danger'); });
  });
  $('#btn-test-fam').on('click', function () {
    $.post(`${API_BASE}/api/envs/${encodeURIComponent(envId)}/test/fam`)
      .done(res => openJobModal('Test FAM Traffic + Check CloudTrail Logs (~65s)', res.jobId))
      .fail(xhr => showToast(apiError(xhr), 'danger'));
  });
}

function renderFAMWarningPanel(port) {
  // Remove any previous instance so we don't double-render on refresh
  $('.fam-dsf-warning').remove();

  const endpoint = `http://${App.serverIP}:${port}`;

  const copyBtn = val =>
    `<button class="btn btn-sm btn-link p-0 ms-1 text-warning copy-btn align-baseline"
             data-val="${esc(val)}" title="Copy to clipboard" style="line-height:1">
       <i class="bi bi-clipboard"></i>
     </button>`;

  const tr = (label, val) =>
    `<tr>
       <td class="text-secondary small text-nowrap pe-3">${esc(label)}</td>
       <td class="font-monospace small">${esc(val)}${copyBtn(val)}</td>
     </tr>`;

  const cloudRows = [
    ['Server Host Name',       App.serverIP],
    ['Server Port',            String(port)],
    ['service_endpoints.s3',   endpoint],
    ['service_endpoints.logs', endpoint],
    ['service_endpoints.rds',  endpoint],
    ['credentials_endpoint',   endpoint],
  ].map(([k, v]) => tr(k, v)).join('');

  const s3Rows = [
    ['Server Host Name', App.serverIP],
    ['Server Port',      String(port)],
  ].map(([k, v]) => tr(k, v)).join('');

  const $panel = $(`
    <div class="alert border-warning fam-dsf-warning mb-3" role="alert"
         style="background:rgba(255,193,7,.07); border-width:1px">
      <div class="d-flex align-items-start gap-2 mb-2">
        <i class="bi bi-exclamation-triangle-fill text-warning mt-1 flex-shrink-0"></i>
        <div>
          <span class="fw-bold text-warning">IMPORTANT — Fix DSF Hub asset endpoints after onboarding</span>
          <p class="small mb-0 mt-1">
            The DSF Hub UI does not allow editing the AWS endpoint URL after an asset is created.
            To point the assets at floci instead of real AWS, you must update the asset documents directly:
          </p>
        </div>
      </div>

      <ol class="small mb-3 ps-4">
        <li>Open DSF Hub → Discover → Asset Index Pattern</li>
        <li>Search for your FAM assets (cloud account + both S3 buckets)</li>
        <li>Edit each document and set the fields below to the actual floci host and port</li>
      </ol>

      <div class="row g-2 mb-2">
        <div class="col-xl-7">
          <div class="card bg-dark border-secondary h-100">
            <div class="card-header small fw-bold py-1">
              <i class="bi bi-person-badge me-1 text-info"></i>CLOUD ACCOUNT asset
            </div>
            <table class="table table-sm table-dark mb-0">${cloudRows}</table>
          </div>
        </div>
        <div class="col-xl-5">
          <div class="card bg-dark border-secondary h-100">
            <div class="card-header small fw-bold py-1">
              <i class="bi bi-bucket me-1 text-info"></i>S3 BUCKET assets
              <span class="text-secondary fw-normal small">(log destination + data source)</span>
            </div>
            <table class="table table-sm table-dark mb-0">${s3Rows}</table>
          </div>
        </div>
      </div>

      <p class="small mb-0 fst-italic text-secondary">
        Without this step the DSF gateway sends API calls to real AWS instead of floci,
        and the fam-user credentials are rejected with <code>InvalidAccessKeyId</code>.
      </p>
    </div>`);

  // Wire copy buttons inside this panel
  $panel.on('click', '.copy-btn', function () {
    navigator.clipboard.writeText($(this).data('val'));
    $(this).html('<i class="bi bi-check-lg text-success"></i>').attr('title', 'Copied!');
    setTimeout(() => $(this).html('<i class="bi bi-clipboard"></i>').attr('title', 'Copy to clipboard'), 1500);
  });

  // Prepend above the two-column layout in the FAM tab
  $('#detail-tab-content').prepend($panel);
}

function renderFAMInfo(fam) {
  const rows = [
    ['Account ID',        fam.accountId],
    ['IAM User',          fam.userName],
    ['IAM User ARN',      fam.userArn],
    ['Source Bucket',     fam.sourceBucket],
    ['Log Bucket',        fam.logBucket],
    ['CloudTrail Trail',  fam.trailName],
    ['Trail Logging',     fam.trailLogging ? '✓ Active' : '✗ Inactive'],
    ['Endpoint URL',      (fam.endpointUrl || '').replace('localhost', App.serverIP)],
    ['Access Key ID',     fam.keyId     || '(run setup first)'],
    ['Secret Key',        fam.secretKey || '(run setup first)'],
  ];
  let html = '<table class="table table-sm fam-info-table mb-0">';
  rows.forEach(([k, v]) => {
    const copyable = v && !v.startsWith('(') && !v.startsWith('✗') && !v.startsWith('✓');
    const btn = copyable
      ? `<button class="btn btn-sm btn-link p-0 ms-1 text-secondary copy-btn"
                 data-val="${esc(v)}"
                 title="Copy ${esc(k)} to clipboard"><i class="bi bi-clipboard"></i></button>`
      : '';
    html += `<tr><th>${esc(k)}</th><td>${esc(v)}${btn}</td></tr>`;
  });
  html += '</table>';
  $('#fam-info-body').html(html).on('click', '.copy-btn', function () {
    navigator.clipboard.writeText($(this).data('val'));
    $(this).html('<i class="bi bi-check-lg text-success"></i>')
           .attr('title', 'Copied!');
    setTimeout(() => $(this).html('<i class="bi bi-clipboard"></i>').attr('title', `Copy ${$(this).closest('tr').find('th').text()} to clipboard`), 1500);
  });
}

/* ── Generator tab ──────────────────────────────────────────────────── */
function initTabGenerator(envId) {
  // FAM section
  loadFAMGenStatus(envId);
  $('#btn-fam-gen-start').on('click', () => {
    $.post(`${API_BASE}/api/envs/${encodeURIComponent(envId)}/generator/fam/start`)
      .done(() => { showToast('FAM generator started', 'success'); loadFAMGenStatus(envId); })
      .fail(xhr => showToast(apiError(xhr), 'danger'));
  });
  $('#btn-fam-gen-stop').on('click', () => {
    $.post(`${API_BASE}/api/envs/${encodeURIComponent(envId)}/generator/fam/stop`)
      .done(() => { showToast('FAM generator stopped', 'warning'); loadFAMGenStatus(envId); })
      .fail(xhr => showToast(apiError(xhr), 'danger'));
  });
  $('#btn-fam-gen-refresh').on('click', () => loadFAMGenStatus(envId));

  // RDS section
  loadRDSGenSection(envId);

  // Periodic refresh
  App.genRefreshTimer = setInterval(() => {
    loadFAMGenStatus(envId);
    refreshRDSGenStatuses(envId);
  }, 3000);
}

function loadFAMGenStatus(envId) {
  $.getJSON(`${API_BASE}/api/envs/${encodeURIComponent(envId)}/generator/fam/logs`).done(res => {
    const $badge = $('#fam-gen-badge');
    if (res.running) {
      $badge.text('Running').removeClass().addClass('badge bg-success');
      $('#btn-fam-gen-start').prop('disabled', true);
      $('#btn-fam-gen-stop').prop('disabled', false);
    } else {
      $badge.text('Stopped').removeClass().addClass('badge bg-secondary');
      $('#btn-fam-gen-start').prop('disabled', false);
      $('#btn-fam-gen-stop').prop('disabled', true);
    }
    const lines = res.lines || [];
    const $log = $('#fam-gen-log');
    if (lines.length) {
      $log.text(lines.join('\n'));
      $log[0].scrollTop = $log[0].scrollHeight;
    }
  });
}

function loadRDSGenSection(envId) {
  $.getJSON(API_BASE + '/api/envs/' + encodeURIComponent(envId)).done(d => {
    const $body = $('#rds-gen-body').empty();
    const rdsInstances = d.rds || [];
    if (!rdsInstances.length) {
      $body.html('<p class="text-secondary small">No RDS instances found. Create one in the Create RDS tab first.</p>');
      return;
    }
    rdsInstances.forEach(rds => renderRDSGenCard(envId, rds, $body));
  });
}

function renderRDSGenCard(envId, rds, $container) {
  const key = encodeURIComponent(envId) + ':' + encodeURIComponent(rds.id);
  const $card = $(`
    <div class="border rounded p-3 mb-3 rds-gen-card" data-instance="${esc(rds.id)}">
      <div class="d-flex align-items-center gap-2 mb-2">
        <span class="fw-bold small font-monospace">${esc(rds.id)}</span>
        <span class="badge bg-warning text-dark">${esc(rds.engine)}</span>
        <span class="badge bg-secondary rds-gen-badge ms-auto">Stopped</span>
      </div>
      <p class="text-secondary small mb-2">
        Generates continuous SQL traffic: INSERT/SELECT/UPDATE/DELETE + simulated errors
        (failed logins, SQL errors, permission violations) for DSF audit log testing.
      </p>
      <div class="d-flex gap-2 mb-2">
        <button class="btn btn-success btn-sm btn-rds-start"
                title="Start background SQL data generator for ${esc(rds.id)} — creates tables, inserts data, simulates errors">
          <i class="bi bi-play-fill me-1"></i>Start Generator
        </button>
        <button class="btn btn-danger btn-sm btn-rds-stop" disabled
                title="Stop the SQL data generator for ${esc(rds.id)}">
          <i class="bi bi-stop-fill me-1"></i>Stop
        </button>
        <button class="btn btn-outline-secondary btn-sm ms-auto btn-rds-refresh"
                title="Refresh SQL activity log">
          <i class="bi bi-arrow-clockwise"></i>
        </button>
      </div>
      <div class="rds-stats small text-muted mb-1 d-none"></div>
      <pre class="job-output gen-log rds-gen-log p-2 m-0 d-none" style="max-height:200px"></pre>
    </div>`);

  $card.find('.btn-rds-start').on('click', function () {
    $(this).prop('disabled', true);
    $.post(`${API_BASE}/api/envs/${encodeURIComponent(envId)}/generator/rds/start`,
      JSON.stringify({ instanceId: rds.id, engine: rds.engine }), null, 'json')
      .done(() => { showToast('RDS generator started for ' + rds.id, 'success'); refreshRDSGenCard(envId, rds.id, $card); })
      .fail(xhr => { $(this).prop('disabled', false); showToast(apiError(xhr), 'danger'); });
  });
  $card.find('.btn-rds-stop').on('click', function () {
    $.post(`${API_BASE}/api/envs/${encodeURIComponent(envId)}/generator/rds/stop`,
      JSON.stringify({ instanceId: rds.id }), null, 'json')
      .done(() => { showToast('RDS generator stopped', 'warning'); refreshRDSGenCard(envId, rds.id, $card); })
      .fail(xhr => showToast(apiError(xhr), 'danger'));
  });
  $card.find('.btn-rds-refresh').on('click', () => refreshRDSGenCard(envId, rds.id, $card));

  if (rds.generatorRunning) {
    refreshRDSGenCard(envId, rds.id, $card);
  }
  $container.append($card);
}

function refreshRDSGenCard(envId, instanceId, $card) {
  $.getJSON(`${API_BASE}/api/envs/${encodeURIComponent(envId)}/generator/rds/logs?instance=${encodeURIComponent(instanceId)}`)
    .done(res => {
      const $badge = $card.find('.rds-gen-badge');
      const $log = $card.find('.rds-gen-log');
      const $stats = $card.find('.rds-stats');
      const $start = $card.find('.btn-rds-start');
      const $stop = $card.find('.btn-rds-stop');

      if (res.running) {
        $badge.text('Running').removeClass('bg-secondary').addClass('bg-success');
        $start.prop('disabled', true);
        $stop.prop('disabled', false);
      } else {
        $badge.text('Stopped').removeClass('bg-success').addClass('bg-secondary');
        $start.prop('disabled', false);
        $stop.prop('disabled', true);
      }
      if (res.lines && res.lines.length) {
        $log.removeClass('d-none').text(res.lines.join('\n'));
        $log[0].scrollTop = $log[0].scrollHeight;
      }
      if (res.stats && res.stats.total > 0) {
        const s = res.stats;
        $stats.removeClass('d-none').html(
          `total: <b>${s.total}</b> &nbsp;|&nbsp; ` +
          `<span class="text-success">ok: ${s.success}</span> &nbsp;` +
          `<span class="text-danger">err: ${s.errors}</span> &nbsp;|&nbsp; ` +
          `ins: ${s.inserts} sel: ${s.selects} upd: ${s.updates} del: ${s.deletes} &nbsp;|&nbsp; ` +
          `<span class="text-warning">perm_denied: ${s.permDenied}</span> ` +
          `grants: ${s.grants} revokes: ${s.revokes} &nbsp;|&nbsp; ` +
          `login_fail: ${s.loginFails} sql_err: ${s.sqlErrors}`
        );
      }
    });
}

function refreshRDSGenStatuses(envId) {
  $('.rds-gen-card').each(function () {
    const instanceId = $(this).data('instance');
    if (instanceId) refreshRDSGenCard(envId, instanceId, $(this));
  });
}

/* ── Job Output Modal ───────────────────────────────────────────────── */
function openJobModal(title, jobId, onDone) {
  $('#jobModalTitle').text(title);
  $('#jobModalBadge').text('Running…').removeClass().addClass('badge bg-secondary ms-2');
  $('#jobOutput').empty();
  $('#jobModalClose').prop('disabled', true);

  const modal = new bootstrap.Modal(document.getElementById('jobModal'));
  modal.show();

  const es = new EventSource(API_BASE + '/api/jobs/' + jobId + '/stream');
  es.onmessage = function (e) {
    if (e.data === '[DONE]') {
      es.close();
      $('#jobModalBadge').text('Done').removeClass().addClass('badge bg-success ms-2');
      $('#jobModalClose').prop('disabled', false);
      if (typeof onDone === 'function') onDone();
      return;
    }
    if (e.data === '[ERROR]') {
      es.close();
      $('#jobModalBadge').text('Error').removeClass().addClass('badge bg-danger ms-2');
      $('#jobModalClose').prop('disabled', false);
      return;
    }
    const $line = $('<div>').text(e.data);
    if (e.data.includes('[ERROR]') || e.data.toLowerCase().startsWith('error')) {
      $line.addClass('text-danger');
    } else if (e.data.startsWith('[CMD]')) {
      $line.addClass('text-info fw-bold');
    } else if (e.data.startsWith('===') || e.data.startsWith('STEP')) {
      $line.addClass('text-warning fw-bold');
    } else if (e.data.startsWith('  ↳')) {
      $line.addClass('text-secondary');
    }
    $('#jobOutput').append($line);
    const el = document.getElementById('jobOutput');
    el.scrollTop = el.scrollHeight;
  };
  es.onerror = function () {
    es.close();
    $('#jobModalBadge').text('Error').removeClass().addClass('badge bg-danger ms-2');
    $('#jobModalClose').prop('disabled', false);
  };
}

/* ── Command Info Offcanvas ─────────────────────────────────────────── */
function showCmdInfo(title, steps) {
  document.getElementById('cmdInfoTitle').textContent = title;
  let html = '<p class="text-secondary small mb-4">These are the actual AWS CLI commands executed during setup. ' +
    'Each command is also printed to the job output log (highlighted in cyan) as it runs, ' +
    'so you can follow along in real time.</p>';
  steps.forEach((s, i) => {
    html +=
      `<div class="cmd-info-step mb-4">` +
        `<div class="d-flex align-items-center gap-2 mb-2">` +
          `<span class="badge bg-primary rounded-pill">${i + 1}</span>` +
          `<strong class="text-light">${esc(s.title)}</strong>` +
        `</div>` +
        (s.note ? `<p class="text-secondary small mb-2">${esc(s.note)}</p>` : '') +
        `<pre class="cmd-block rounded p-3 m-0">${esc(s.cmd)}</pre>` +
      `</div>`;
  });
  document.getElementById('cmdInfoBody').innerHTML = html;
  new bootstrap.Offcanvas(document.getElementById('cmdInfoOffcanvas')).show();
}

function getCmdStepsRDS(engine, instanceId, endpoint) {
  const ep = '--endpoint-url ' + endpoint;
  switch (engine) {
    case 'postgres': return _rdsStepsPostgres(instanceId, ep);
    case 'mysql':    return _rdsStepsMySQL(instanceId, ep);
    case 'mariadb':  return _rdsStepsMariaDB(instanceId, ep);
    default: return [];
  }
}

function _rdsStepsPostgres(id, ep) {
  const paramGroup = id + '-pgaudit';
  const logGroup   = '/aws/rds/instance/' + id + '/postgresql';
  return [
    {
      title: 'Create PostgreSQL DB instance',
      note:  'Provisions the RDS instance in LocalStack. The --no-publicly-accessible flag mirrors a real production setup.',
      cmd:
        'aws rds create-db-instance \\\n' +
        '  --db-instance-identifier ' + id + ' \\\n' +
        '  --engine postgres \\\n' +
        '  --engine-version 16.1 \\\n' +
        '  --db-instance-class db.t3.micro \\\n' +
        '  --allocated-storage 20 \\\n' +
        '  --master-username admin \\\n' +
        '  --master-user-password secret123 \\\n' +
        '  --db-name dsf_lab \\\n' +
        '  --no-multi-az --no-publicly-accessible \\\n' +
        '  ' + ep,
    },
    {
      title: 'Poll until instance is available',
      note:  'Loops on describe-db-instances until DBInstanceStatus == "available" (~30 s on LocalStack).',
      cmd:
        'aws rds describe-db-instances \\\n' +
        '  --db-instance-identifier ' + id + ' \\\n' +
        '  --query \'DBInstances[0].DBInstanceStatus\' \\\n' +
        '  --output text \\\n' +
        '  ' + ep,
    },
    {
      title: 'Create parameter group for pgaudit',
      note:  'Parameter groups store engine configuration.  The pgaudit extension must be loaded via shared_preload_libraries.',
      cmd:
        'aws rds create-db-parameter-group \\\n' +
        '  --db-parameter-group-name ' + paramGroup + ' \\\n' +
        '  --db-parameter-group-family postgres16 \\\n' +
        '  --description "pgaudit parameter group for DSF Hub" \\\n' +
        '  ' + ep,
    },
    {
      title: 'Enable pgaudit in the parameter group',
      cmd:
        'aws rds modify-db-parameter-group \\\n' +
        '  --db-parameter-group-name ' + paramGroup + ' \\\n' +
        '  --parameters \\\n' +
        '      ParameterName=shared_preload_libraries,ParameterValue=pgaudit,ApplyMethod=pending-reboot \\\n' +
        '      ParameterName=pgaudit.log,ParameterValue=all,ApplyMethod=immediate \\\n' +
        '      ParameterName=pgaudit.log_catalog,ParameterValue=1,ApplyMethod=immediate \\\n' +
        '  ' + ep,
    },
    {
      title: 'Attach parameter group + enable CloudWatch log export',
      note:  'EnableLogTypes=postgresql tells RDS to stream the PostgreSQL logs (which include pgaudit output) to CloudWatch Logs.',
      cmd:
        'aws rds modify-db-instance \\\n' +
        '  --db-instance-identifier ' + id + ' \\\n' +
        '  --db-parameter-group-name ' + paramGroup + ' \\\n' +
        '  --cloudwatch-logs-export-configuration \'{"EnableLogTypes":["postgresql"]}\' \\\n' +
        '  --apply-immediately \\\n' +
        '  ' + ep,
    },
    {
      title: 'Create CloudWatch log group + set retention',
      note:  'RDS will write logs to this group.  DSF Hub reads from here when monitoring PostgreSQL audit events.',
      cmd:
        'aws logs create-log-group \\\n' +
        '  --log-group-name ' + logGroup + ' \\\n' +
        '  ' + ep + '\n\n' +
        'aws logs put-retention-policy \\\n' +
        '  --log-group-name ' + logGroup + ' \\\n' +
        '  --retention-in-days 90 \\\n' +
        '  ' + ep,
    },
  ];
}

function _rdsStepsMySQL(id, ep) {
  const optGroup = id + '-audit';
  const logGroup = '/aws/rds/instance/' + id + '/audit';
  return [
    {
      title: 'Create MySQL DB instance',
      cmd:
        'aws rds create-db-instance \\\n' +
        '  --db-instance-identifier ' + id + ' \\\n' +
        '  --engine mysql \\\n' +
        '  --engine-version 8.0.36 \\\n' +
        '  --db-instance-class db.t3.micro \\\n' +
        '  --allocated-storage 20 \\\n' +
        '  --master-username admin \\\n' +
        '  --master-user-password secret123 \\\n' +
        '  --db-name dsf_lab \\\n' +
        '  --no-multi-az --no-publicly-accessible \\\n' +
        '  ' + ep,
    },
    {
      title: 'Poll until instance is available',
      cmd:
        'aws rds describe-db-instances \\\n' +
        '  --db-instance-identifier ' + id + ' \\\n' +
        '  --query \'DBInstances[0].DBInstanceStatus\' \\\n' +
        '  --output text \\\n' +
        '  ' + ep,
    },
    {
      title: 'Create option group for MARIADB_AUDIT_PLUGIN',
      note:  'MySQL on RDS uses the MariaDB Audit Plugin for activity logging.  Option groups attach plugins to instances.',
      cmd:
        'aws rds create-option-group \\\n' +
        '  --option-group-name ' + optGroup + ' \\\n' +
        '  --engine-name mysql \\\n' +
        '  --major-engine-version 8.0 \\\n' +
        '  --option-group-description "Audit plugin for DSF Hub" \\\n' +
        '  ' + ep,
    },
    {
      title: 'Add MARIADB_AUDIT_PLUGIN to the option group',
      cmd:
        'aws rds add-option-to-option-group \\\n' +
        '  --option-group-name ' + optGroup + ' \\\n' +
        '  --apply-immediately \\\n' +
        '  --options OptionName=MARIADB_AUDIT_PLUGIN,OptionSettings=[\\\n' +
        '      {Name=SERVER_AUDIT_EVENTS,Value=CONNECT\\,QUERY},\\\n' +
        '      {Name=SERVER_AUDIT_FILE_ROTATIONS,Value=20}] \\\n' +
        '  ' + ep,
    },
    {
      title: 'Attach option group + enable CloudWatch log export',
      note:  'EnableLogTypes=audit streams the MariaDB Audit Plugin output to CloudWatch Logs.',
      cmd:
        'aws rds modify-db-instance \\\n' +
        '  --db-instance-identifier ' + id + ' \\\n' +
        '  --option-group-name ' + optGroup + ' \\\n' +
        '  --cloudwatch-logs-export-configuration \'{"EnableLogTypes":["audit"]}\' \\\n' +
        '  --apply-immediately \\\n' +
        '  ' + ep,
    },
    {
      title: 'Create CloudWatch log group + set retention',
      cmd:
        'aws logs create-log-group \\\n' +
        '  --log-group-name ' + logGroup + ' \\\n' +
        '  ' + ep + '\n\n' +
        'aws logs put-retention-policy \\\n' +
        '  --log-group-name ' + logGroup + ' \\\n' +
        '  --retention-in-days 90 \\\n' +
        '  ' + ep,
    },
  ];
}

function _rdsStepsMariaDB(id, ep) {
  const optGroup = id + '-audit';
  const logGroup = '/aws/rds/instance/' + id + '/audit';
  return [
    {
      title: 'Create MariaDB DB instance',
      cmd:
        'aws rds create-db-instance \\\n' +
        '  --db-instance-identifier ' + id + ' \\\n' +
        '  --engine mariadb \\\n' +
        '  --engine-version 10.11.6 \\\n' +
        '  --db-instance-class db.t3.micro \\\n' +
        '  --allocated-storage 20 \\\n' +
        '  --master-username admin \\\n' +
        '  --master-user-password secret123 \\\n' +
        '  --db-name dsf_lab \\\n' +
        '  --no-multi-az --no-publicly-accessible \\\n' +
        '  ' + ep,
    },
    {
      title: 'Poll until instance is available',
      cmd:
        'aws rds describe-db-instances \\\n' +
        '  --db-instance-identifier ' + id + ' \\\n' +
        '  --query \'DBInstances[0].DBInstanceStatus\' \\\n' +
        '  --output text \\\n' +
        '  ' + ep,
    },
    {
      title: 'Create option group for MARIADB_AUDIT_PLUGIN',
      note:  'MariaDB natively ships the audit plugin.  The option group configures and enables it.',
      cmd:
        'aws rds create-option-group \\\n' +
        '  --option-group-name ' + optGroup + ' \\\n' +
        '  --engine-name mariadb \\\n' +
        '  --major-engine-version 10.11 \\\n' +
        '  --option-group-description "Audit plugin for DSF Hub" \\\n' +
        '  ' + ep,
    },
    {
      title: 'Add MARIADB_AUDIT_PLUGIN to the option group',
      cmd:
        'aws rds add-option-to-option-group \\\n' +
        '  --option-group-name ' + optGroup + ' \\\n' +
        '  --apply-immediately \\\n' +
        '  --options OptionName=MARIADB_AUDIT_PLUGIN,OptionSettings=[\\\n' +
        '      {Name=SERVER_AUDIT_EVENTS,Value=CONNECT\\,QUERY},\\\n' +
        '      {Name=SERVER_AUDIT_FILE_ROTATIONS,Value=20}] \\\n' +
        '  ' + ep,
    },
    {
      title: 'Attach option group + enable CloudWatch log export',
      cmd:
        'aws rds modify-db-instance \\\n' +
        '  --db-instance-identifier ' + id + ' \\\n' +
        '  --option-group-name ' + optGroup + ' \\\n' +
        '  --cloudwatch-logs-export-configuration \'{"EnableLogTypes":["audit"]}\' \\\n' +
        '  --apply-immediately \\\n' +
        '  ' + ep,
    },
    {
      title: 'Create CloudWatch log group + set retention',
      cmd:
        'aws logs create-log-group \\\n' +
        '  --log-group-name ' + logGroup + ' \\\n' +
        '  ' + ep + '\n\n' +
        'aws logs put-retention-policy \\\n' +
        '  --log-group-name ' + logGroup + ' \\\n' +
        '  --retention-in-days 90 \\\n' +
        '  ' + ep,
    },
  ];
}

function getCmdStepsFAM(suffix, endpoint) {
  const ep       = '--endpoint-url ' + endpoint;
  const user     = 'fam-user-' + suffix;
  const srcBkt   = 'fam-source-' + suffix;
  const logBkt   = 'fam-logs-' + suffix;
  const trail    = 'fam-trail-' + suffix;
  return [
    {
      title: 'Get AWS account ID',
      note:  'Used to build IAM ARNs and bucket policies for CloudTrail.',
      cmd:   'aws sts get-caller-identity --query Account --output text \\\n  ' + ep,
    },
    {
      title: 'Create IAM user for FAM',
      cmd:
        'aws iam create-user --user-name ' + user + ' \\\n  ' + ep + '\n\n' +
        '# Attach S3 read policy (inline)\n' +
        'aws iam put-user-policy \\\n' +
        '  --user-name ' + user + ' \\\n' +
        '  --policy-name FAMS3ReadAccess \\\n' +
        '  --policy-document \'{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:GetObject","s3:ListBucket"],"Resource":"*"}]}\' \\\n' +
        '  ' + ep + '\n\n' +
        '# Attach managed CloudTrail policy\n' +
        'aws iam attach-user-policy \\\n' +
        '  --user-name ' + user + ' \\\n' +
        '  --policy-arn arn:aws:iam::aws:policy/AWSCloudTrail_FullAccess \\\n' +
        '  ' + ep,
    },
    {
      title: 'Create access key for the FAM user',
      note:  'The Access Key ID and Secret are stored by the builder for later DSF Hub onboarding.',
      cmd:
        'aws iam create-access-key \\\n' +
        '  --user-name ' + user + ' \\\n' +
        '  ' + ep,
    },
    {
      title: 'Create S3 buckets',
      note:  srcBkt + ' = data source monitored by FAM.  ' + logBkt + ' = CloudTrail log destination.',
      cmd:
        'aws s3api create-bucket --bucket ' + srcBkt + ' \\\n  ' + ep + '\n\n' +
        'aws s3api create-bucket --bucket ' + logBkt + ' \\\n  ' + ep,
    },
    {
      title: 'Apply bucket policy so CloudTrail can write to the log bucket',
      note:  'CloudTrail needs s3:PutObject permission on the log bucket with the correct key prefix.',
      cmd:
        'aws s3api put-bucket-policy \\\n' +
        '  --bucket ' + logBkt + ' \\\n' +
        '  --policy \'{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"cloudtrail.amazonaws.com"},"Action":"s3:PutObject","Resource":"arn:aws:s3:::' + logBkt + '/AWSLogs/*"}]}\' \\\n' +
        '  ' + ep,
    },
    {
      title: 'Create CloudTrail trail',
      note:  'The trail captures management events and S3 data events (PUT/GET/LIST/DELETE on the source bucket).',
      cmd:
        'aws cloudtrail create-trail \\\n' +
        '  --name ' + trail + ' \\\n' +
        '  --s3-bucket-name ' + logBkt + ' \\\n' +
        '  --include-global-service-events \\\n' +
        '  --is-multi-region-trail \\\n' +
        '  ' + ep,
    },
    {
      title: 'Configure S3 data event selectors',
      note:  'Without this, CloudTrail only records management events.  Adding a DataResources selector for the source bucket captures every S3 object operation.',
      cmd:
        'aws cloudtrail put-event-selectors \\\n' +
        '  --trail-name ' + trail + ' \\\n' +
        '  --event-selectors \'[{"ReadWriteType":"All","IncludeManagementEvents":true,"DataResources":[{"Type":"AWS::S3::Object","Values":["arn:aws:s3:::' + srcBkt + '/"]}]}]\' \\\n' +
        '  ' + ep,
    },
    {
      title: 'Start logging',
      note:  'Logging is not active until you call start-logging — even after creating the trail.',
      cmd:
        'aws cloudtrail start-logging \\\n' +
        '  --name ' + trail + ' \\\n' +
        '  ' + ep,
    },
  ];
}

/* ── Utilities ──────────────────────────────────────────────────────── */
function labelForEnv(env) {
  if (env.id === 'floci-local-aws') return 'Default Env';
  if (env.cloud === 'gcp' || (env.id && env.id.startsWith('floci-gcp'))) {
    const slot = env.slot || env.id.replace('floci-gcp', '');
    return 'GCP Env ' + slot;
  }
  return 'Env ' + (env.slot || env.id.replace('floci-env', ''));
}

function statusBadgeClass(s) {
  switch (s) {
    case 'running': return 'bg-success';
    case 'stopped':
    case 'exited':  return 'bg-secondary';
    default:        return 'bg-warning text-dark';
  }
}

function setBreadcrumb(envId) {
  $('#nav-breadcrumb').text(envId ? '/ ' + envId : '');
}

function esc(s) {
  return String(s || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function apiError(xhr) {
  try { return JSON.parse(xhr.responseText).error || xhr.statusText; }
  catch { return xhr.statusText || 'Unknown error'; }
}

/* ── Azure env lifecycle ─────────────────────────────────────────────── */
function deployNewAZEnv() {
  if (!confirm('Deploy a new Azure environment?\nThis will start floci-az and az-log-shipper containers.')) return;
  const $btn = $('#btn-deploy-az').prop('disabled', true)
    .html('<span class="spinner-border spinner-border-sm me-1"></span>Deploying…');
  $.post(API_BASE + '/api/az-envs')
    .done(res => {
      $btn.prop('disabled', false).html('<i class="bi bi-microsoft me-1"></i>Deploy Azure Env');
      openJobModal('Deploying New Azure Environment', res.jobId, () => loadEnvs());
    })
    .fail(xhr => {
      $btn.prop('disabled', false).html('<i class="bi bi-microsoft me-1"></i>Deploy Azure Env');
      showToast('Azure Deploy failed: ' + apiError(xhr), 'danger');
    });
}

function destroyAZEnv(env) {
  if (!confirm(`Destroy Azure environment ${env.id}?\nThis will stop all containers and delete all data.`)) return;
  $.ajax({ url: API_BASE + '/api/az-envs/' + encodeURIComponent(env.id), method: 'DELETE' })
    .done(res => openJobModal('Destroying ' + env.id, res.jobId, () => loadEnvs()))
    .fail(xhr => showToast('Destroy failed: ' + apiError(xhr), 'danger'));
}

/* ── Azure env detail page ───────────────────────────────────────────── */
function showAZEnvDetail(envId) {
  const tpl = document.getElementById('tpl-az-env-detail').content.cloneNode(true);
  $('#main-content').empty().append(tpl);
  setBreadcrumb(envId);

  $('#main-content').on('click', 'a[href="#"]', e => {
    if ($(e.target).closest('#az-detail-tabs').length) return;
    e.preventDefault();
    window.location.hash = '#/';
  });

  $('#az-detail-tabs').on('click', 'a.nav-link', function (e) {
    e.preventDefault();
    $('#az-detail-tabs a.nav-link').removeClass('active');
    $(this).addClass('active');
    loadAZTab($(this).data('azTab'), envId);
  });

  loadAZEnvHeader(envId);
  loadAZTab('azdb', envId);
  App.refreshTimer = setInterval(() => {
    if ($('[data-az-tab="azdb"]').hasClass('active') || !$('#az-detail-tabs .nav-link.active').length) {
      refreshAZDatabases(envId);
    }
  }, 8000);
}

function loadAZEnvHeader(envId) {
  $.getJSON(API_BASE + '/api/az-envs/' + encodeURIComponent(envId)).done(d => {
    $('#az-detail-title').text(labelForEnv(d));
    $('#az-detail-status').text(d.status).removeClass().addClass('badge ' + statusBadgeClass(d.status));
    $('#az-detail-port').text(d.flociPort || '—');
    $('#az-detail-sub').text((d.accountId || '—').slice(-8));
    $('#az-detail-network').text(d.network || '—');
  });
}

function loadAZTab(tab, envId) {
  const $content = $('#az-detail-tab-content');
  const tplId = tab === 'azdb'          ? 'tpl-tab-azdb'
              : tab === 'create-azdb'   ? 'tpl-tab-create-azdb'
              : 'tpl-tab-az-generator';
  $content.empty().append(document.getElementById(tplId).content.cloneNode(true));

  if (App.azGenTimer) { clearInterval(App.azGenTimer); App.azGenTimer = null; }

  switch (tab) {
    case 'azdb':          initTabAZDB(envId); break;
    case 'create-azdb':   initTabCreateAZDB(envId); break;
    case 'az-generator':  initTabAZGenerator(envId); break;
  }
}

/* ── Azure databases tab ─────────────────────────────────────────────── */
function initTabAZDB(envId) {
  refreshAZDatabases(envId);
  $('#btn-refresh-az-detail').on('click', () => refreshAZDatabases(envId));

  $('#az-export-server-ip').val(App.serverIP === 'localhost' ? '' : App.serverIP);
  $('#az-export-server-ip').on('input', function () {
    App.serverIP = $(this).val().trim() || 'localhost';
    localStorage.setItem('serverIP', App.serverIP === 'localhost' ? '' : App.serverIP);
    $('#nav-server-ip').val(App.serverIP === 'localhost' ? '' : App.serverIP);
  });

  const lsGwKey = 'export-gw-' + envId;
  const savedGw = localStorage.getItem(lsGwKey) || '';
  if (savedGw) $('#az-export-gateway-name').val(savedGw);
  $('#az-export-gateway-name').on('input', function () {
    localStorage.setItem(lsGwKey, $(this).val());
  });

  $('#btn-export-az-assets').on('click', function () {
    const serverIP    = encodeURIComponent($('#az-export-server-ip').val().trim());
    const gatewayName = encodeURIComponent($('#az-export-gateway-name').val().trim());
    const url = `${API_BASE}/api/az-envs/${encodeURIComponent(envId)}/export?serverIP=${serverIP}&gatewayName=${gatewayName}`;
    const $a = $('<a>').attr({ href: url, download: '' }).appendTo('body');
    $a[0].click();
    $a.remove();
  });
}

function refreshAZDatabases(envId) {
  $.getJSON(API_BASE + '/api/az-envs/' + encodeURIComponent(envId)).done(d => {
    renderAZDBTable(d.databases || [], envId);
  });
}

function renderAZDBTable(rows, envId) {
  const $tbody = $('#azdb-tbody').empty();
  if (!rows.length) {
    $tbody.append('<tr><td colspan="5" class="text-center text-secondary p-3">No Azure databases — create one in the Create Database tab</td></tr>');
    return;
  }
  rows.forEach(db => {
    const $tr = $(`<tr>
      <td class="font-monospace small">${esc(db.id)}</td>
      <td><span class="badge bg-secondary">${esc(db.engine)}</span></td>
      <td><span class="badge ${db.status === 'Ready' ? 'bg-success' : 'bg-warning text-dark'}">${esc(db.status)}</span></td>
      <td class="font-monospace small text-secondary">${esc(db.endpoint || '—')}</td>
      <td class="text-center">
        <button class="btn btn-sm btn-outline-info btn-azdb-info me-1"
                data-instance="${esc(db.id)}" data-engine="${esc(db.engine)}"
                title="Show full database info: Event Hub, diagnostic settings, credentials">
          <i class="bi bi-info-circle"></i>
        </button>
        <button class="btn btn-sm btn-outline-secondary btn-test-azdb"
                data-instance="${esc(db.id)}" data-engine="${esc(db.engine)}"
                title="Generate SQL traffic and verify Event Hub receives audit logs">
          <i class="bi bi-play-fill"></i>
        </button>
      </td>
    </tr>`);
    $tbody.append($tr);
  });
  $tbody.find('.btn-azdb-info').on('click', function () {
    showAZDBDetail(envId, $(this).data('instance'), $(this).data('engine'));
  });
  $tbody.find('.btn-test-azdb').on('click', function () {
    const inst = $(this).data('instance');
    const eng  = $(this).data('engine');
    $.post(`${API_BASE}/api/az-envs/${encodeURIComponent(envId)}/test/azdb/${eng}`,
           JSON.stringify({ instanceId: inst }),
           null, 'json')
      .done(res => openJobModal(`Test Azure ${eng} — ${inst}`, res.jobId))
      .fail(xhr => showToast('Test failed: ' + apiError(xhr), 'danger'));
  });
}

function showAZDBDetail(envId, instanceId, engine) {
  document.getElementById('azDBOffcanvasTitle').textContent = instanceId + ' (' + engine + ')';
  document.getElementById('azDBOffcanvasBody').innerHTML =
    '<div class="d-flex justify-content-center align-items-center p-5"><div class="spinner-border spinner-border-sm text-info"></div></div>';
  const oc = new bootstrap.Offcanvas(document.getElementById('azDBOffcanvas'));
  oc.show();
  $.getJSON(`${API_BASE}/api/az-envs/${encodeURIComponent(envId)}/azdb/detail?instance=${encodeURIComponent(instanceId)}&engine=${encodeURIComponent(engine)}`)
    .done(d => renderAZDBDetailPanel(d))
    .fail(() => {
      document.getElementById('azDBOffcanvasBody').innerHTML =
        '<div class="p-4 text-danger">Failed to load database details.</div>';
    });
}

function renderAZDBDetailPanel(d) {
  const ip = App.serverIP || 'localhost';
  const proxyEndpoint = d.proxyPort ? `${ip}:${d.proxyPort}` : '(proxy not running — run setup script first)';

  let html = `<div class="p-3 border-bottom border-secondary-subtle">
    <div class="d-flex align-items-center gap-2 mb-1">
      <span class="badge bg-info text-dark"><i class="bi bi-microsoft me-1"></i>Azure</span>
      <span class="badge bg-secondary">${esc(d.engine)}</span>
      <span class="badge ${d.status === 'Ready' ? 'bg-success' : 'bg-warning text-dark'}">${esc(d.status)}</span>
    </div>
    <div class="font-monospace small text-secondary">${esc(d.id)}</div>
  </div>`;

  html += '<table class="table table-sm fam-info-table mb-0">';
  const rows = [
    ['Engine',           d.engine + ' ' + (d.engineVersion || '')],
    ['Status',           d.status],
    ['FQDN',             d.endpoint || '—'],
    ['Host Proxy',       proxyEndpoint],
    ['Master User',      d.masterUser],
    ['Master Pass',      d.masterPass],
    ['Audit User',       d.auditUser],
    ['Audit Pass',       d.auditPass],
    ['Subscription',     d.subscriptionId],
    ['Resource Group',   d.resourceGroup],
    ['Event Hub NS',     d.eventHubNamespace],
    ['Event Hub',        d.eventHubName],
    ['Diag Setting',     d.diagnosticSettingName],
    ['Floci-AZ URL',     d.flociEndpoint],
  ];
  rows.forEach(([k, v]) => {
    html += `<tr><td class="text-secondary small" style="width:140px">${esc(k)}</td>
                 <td class="font-monospace small">${esc(String(v || '—'))}</td></tr>`;
  });

  // Connection strings
  const jdbcBase = d.proxyPort ? `localhost:${d.proxyPort}` : (d.host || 'localhost');
  let connStr = '';
  if (d.engine === 'postgres') {
    connStr = `jdbc:postgresql://${jdbcBase}/postgres?user=${d.masterUser}&password=${d.masterPass}&sslmode=disable`;
  } else {
    connStr = `jdbc:${d.engine}://${jdbcBase}/dsf_lab?user=${d.masterUser}&password=${d.masterPass}&useSSL=false&allowPublicKeyRetrieval=true`;
  }
  html += `<tr><td class="text-secondary small">JDBC (proxy)</td>
               <td class="font-monospace small" style="word-break:break-all">${esc(connStr)}</td></tr>`;

  html += '</table>';
  document.getElementById('azDBOffcanvasBody').innerHTML = html;
}

/* ── Create Azure database tab ───────────────────────────────────────── */
function initTabCreateAZDB(envId) {
  loadAZDBSuggest(envId);
  $('#azdb-engine').on('change', () => loadAZDBSuggest(envId));
  $('#btn-create-azdb').on('click', () => {
    const engine = $('#azdb-engine').val();
    const instanceId = $('#azdb-suggest-label').data('suggested') || '';
    if (!instanceId) { showToast('No suggested name available', 'warning'); return; }
    $.post(`${API_BASE}/api/az-envs/${encodeURIComponent(envId)}/azdb`,
           JSON.stringify({ engine, instanceId }),
           null, 'json')
      .done(res => openJobModal(`Create Azure ${engine} — ${instanceId}`, res.jobId, () => {
        window.location.hash = '#/az-env/' + encodeURIComponent(envId);
      }))
      .fail(xhr => showToast('Create failed: ' + apiError(xhr), 'danger'));
  });
}

function loadAZDBSuggest(envId) {
  const engine = $('#azdb-engine').val();
  $.getJSON(`${API_BASE}/api/az-envs/${encodeURIComponent(envId)}/azdb/suggest?engine=${engine}`)
    .done(d => {
      $('#azdb-suggest-label').text('→ ' + (d.suggested || '')).data('suggested', d.suggested);
    });
}

/* ── Azure generator tab ─────────────────────────────────────────────── */
function initTabAZGenerator(envId) {
  $.getJSON(API_BASE + '/api/az-envs/' + encodeURIComponent(envId)).done(d => {
    const $body = $('#az-gen-body').empty();
    const dbs = d.databases || [];
    if (!dbs.length) {
      $body.html('<p class="text-secondary small">No Azure databases — create one first.</p>');
      return;
    }
    dbs.forEach(db => {
      const key = `az:${envId}:${db.id}`;
      const $card = $(`<div class="mb-3 p-3 border border-secondary-subtle rounded">
        <div class="d-flex justify-content-between align-items-center mb-2">
          <span class="fw-semibold">${esc(db.id)} <span class="badge bg-secondary ms-1">${esc(db.engine)}</span></span>
          <div class="d-flex gap-2">
            <button class="btn btn-sm btn-success btn-start-az-gen" data-instance="${esc(db.id)}" data-engine="${esc(db.engine)}">
              <i class="bi bi-play-fill me-1"></i>Start
            </button>
            <button class="btn btn-sm btn-danger btn-stop-az-gen" data-instance="${esc(db.id)}">
              <i class="bi bi-stop-fill me-1"></i>Stop
            </button>
          </div>
        </div>
        <pre class="bg-body-secondary rounded p-2 small font-monospace az-gen-log" style="max-height:200px;overflow-y:auto" id="az-gen-log-${esc(db.id)}">Idle</pre>
      </div>`);
      $body.append($card);
    });

    $body.find('.btn-start-az-gen').on('click', function () {
      const inst = $(this).data('instance');
      const eng  = $(this).data('engine');
      $.post(`${API_BASE}/api/az-envs/${encodeURIComponent(envId)}/generator/azdb/start`,
             JSON.stringify({ instanceId: inst, engine: eng }), null, 'json')
        .done(() => { showToast('Generator started for ' + inst, 'success'); startAZGenPoll(envId, inst); })
        .fail(xhr => showToast('Start failed: ' + apiError(xhr), 'danger'));
    });

    $body.find('.btn-stop-az-gen').on('click', function () {
      const inst = $(this).data('instance');
      $.post(`${API_BASE}/api/az-envs/${encodeURIComponent(envId)}/generator/azdb/stop`,
             JSON.stringify({ instanceId: inst }), null, 'json')
        .done(() => showToast('Generator stopped for ' + inst, 'secondary'))
        .fail(xhr => showToast('Stop failed: ' + apiError(xhr), 'danger'));
    });

    // Start polling for all instances
    dbs.forEach(db => startAZGenPoll(envId, db.id));
  });
}

function startAZGenPoll(envId, instanceId) {
  if (!App.azPollFns) App.azPollFns = [];

  const poll = () => {
    $.getJSON(`${API_BASE}/api/az-envs/${encodeURIComponent(envId)}/generator/azdb/logs?instance=${encodeURIComponent(instanceId)}`)
      .done(d => {
        const $log = $(`#az-gen-log-${CSS.escape(instanceId)}`);
        if ($log.length && d.lines && d.lines.length) {
          $log.text(d.lines.join('\n'));
          $log.scrollTop($log[0].scrollHeight);
        }
      });
  };

  App.azPollFns.push(poll);
  poll();

  if (!App.azGenTimer) {
    App.azGenTimer = setInterval(() => {
      if ($('#az-gen-body').length) {
        App.azPollFns.forEach(fn => fn());
      }
    }, 3000);
  }
}

function showToast(msg, type) {
  const id = 'toast-' + Date.now();
  let $c = $('#toast-container');
  if (!$c.length) {
    $c = $('<div id="toast-container" class="position-fixed bottom-0 end-0 p-3" style="z-index:9999">');
    $('body').append($c);
  }
  $c.append(`<div id="${id}" class="toast align-items-center text-bg-${type} border-0" role="alert">
    <div class="d-flex">
      <div class="toast-body">${esc(msg)}</div>
      <button type="button" class="btn-close btn-close-white me-2 m-auto" data-bs-dismiss="toast"></button>
    </div>
  </div>`);
  const t = new bootstrap.Toast(document.getElementById(id), { delay: 4000 });
  t.show();
  document.getElementById(id).addEventListener('hidden.bs.toast', e => e.target.remove());
}
