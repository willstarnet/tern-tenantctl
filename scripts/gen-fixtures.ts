// Writes tests/fixtures/<name>.json and <name>.txt: what tenantctl prints for synthetic results,
// in JSON and in its terminal table format, rendered by tenantctl's own output code so the lens
// specs read exactly what the CLI prints. Needs a tenantctl checkout:
//
//   bun scripts/gen-fixtures.ts [path/to/tenantctl]   (default ../tenantctl)
//
// The data is invented (Contoso); never put real tenant data in a fixture.
import { mkdirSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

const src = resolve(process.argv[2] ?? join(import.meta.dir, '..', '..', 'tenantctl'));
// Dynamic: the tenantctl checkout is chosen at run time (argv), so no static path exists.
const output = await import(join(src, 'src/core/output.ts'));
const errors = await import(join(src, 'src/core/errors.ts'));
const out = join(import.meta.dir, '..', 'tests', 'fixtures');
mkdirSync(out, { recursive: true });

type Fixture =
  | { kind: 'success'; command: string; result: unknown; fields?: string[] }
  | { kind: 'error'; code: string; message: string; hint?: string; details?: unknown; requestId?: string }
  | { kind: 'confirm'; payload: Record<string, unknown> };

const fixtures: Record<string, Fixture> = {
  'troubleshoot-user': {
    kind: 'success',
    command: 'troubleshoot user',
    result: {
      user: {
        id: '3f1c2a9e-5b7d-4c11-9e2a-7d8b6c5a4f30',
        displayName: 'Jane Doe',
        userPrincipalName: 'jane@contoso.com',
      },
      verdict: '2 problems for jane@contoso.com: Account is disabled and 1 more (could not check: risk).',
      findings: [
        {
          severity: 'high',
          area: 'account',
          issue: 'Account is disabled',
          detail: 'Sign-ins are blocked until it is enabled again.',
          next: 'tenantctl entra users enable jane@contoso.com',
        },
        {
          severity: 'medium',
          area: 'licenses',
          issue: 'No Exchange Online plan assigned',
          detail: 'The mailbox is soft-deleted 30 days after the last plan is removed.',
          next: 'tenantctl entra users licenses jane@contoso.com',
        },
        {
          severity: 'low',
          area: 'sign-in',
          issue: '3 sign-in failures with 50126 InvalidUserNameOrPassword (succeeded since)',
          detail: '',
          next: 'tenantctl entra signin-error 50126',
        },
        {
          severity: 'info',
          area: 'mailbox',
          issue: 'Inbox rule "Newsletters" moves mail to Reading',
          detail: 'Explains "missing" mail that was in fact delivered.',
          next: 'tenantctl exchange rules list jane@contoso.com',
        },
      ],
      unavailable: [
        { section: 'risk', code: 'FORBIDDEN', message: 'Risk detections need Entra ID P2.' },
      ],
      account: {
        enabled: false,
        userType: 'Member',
        createdDateTime: '2024-02-01T09:12:00Z',
        lastPasswordChangeDateTime: '2026-10-09T08:00:00Z',
        daysSincePasswordChange: 42,
        isSynced: false,
      },
      mfa: {
        registered: true,
        methods: [
          { type: 'Password', createdDateTime: '2024-02-01T09:12:00Z' },
          { type: 'Microsoft Authenticator', detail: 'iPhone 15, app 6.8.50' },
        ],
      },
      signins: {
        window: 'last 7 days',
        total: 48,
        failures: 3,
        lastSuccess: '2026-11-19T16:02:11Z',
        failureGroups: [
          {
            errorCode: 50126,
            name: 'InvalidUserNameOrPassword',
            count: 3,
            lastSeen: '2026-11-18T07:44:00Z',
            apps: ['Microsoft Teams'],
          },
        ],
      },
      devices: [
        {
          id: '0b8d1c3e-8f4e-4b39-9a51-6c2f0e7d1a11',
          deviceName: 'LAPTOP-0042',
          os: 'Windows',
          complianceState: 'noncompliant',
          lastSyncDateTime: '2026-11-17T10:00:00Z',
          daysSinceLastSync: 3,
          azureADDeviceId: '6d1f0a2b-3c4d-4e5f-8a9b-0c1d2e3f4a5b',
        },
        {
          id: '5e2a7b90-1d44-4f6a-8c3b-2b9d0a6e7f22',
          deviceName: "Jane's iPhone",
          os: 'iOS',
          complianceState: 'compliant',
          lastSyncDateTime: '2026-11-20T08:30:00Z',
          daysSinceLastSync: 0,
        },
      ],
      mailbox: { forwardingSmtpAddress: null, autoReply: 'disabled', size: '2.1 GB' },
    },
  },
  'devices-list': {
    kind: 'success',
    command: 'intune devices list',
    result: {
      items: [
        {
          id: '0b8d1c3e-8f4e-4b39-9a51-6c2f0e7d1a11',
          deviceName: 'LAPTOP-0042',
          user: 'jane@contoso.com',
          os: 'Windows',
          osVersion: '10.0.26100.2314',
          complianceState: 'noncompliant',
          lastSyncDateTime: '2026-11-17T10:00:00Z',
          isEncrypted: true,
        },
        {
          id: '5e2a7b90-1d44-4f6a-8c3b-2b9d0a6e7f22',
          deviceName: "Jane's iPhone",
          user: 'jane@contoso.com',
          os: 'iOS',
          osVersion: '18.1',
          complianceState: 'compliant',
          lastSyncDateTime: '2026-11-20T08:30:00Z',
          isEncrypted: true,
        },
        {
          id: '9c4f6e21-3a8b-4d70-b215-8e1f5c3d2b33',
          deviceName: 'MAC-0007',
          user: 'bob@contoso.com',
          os: 'macOS',
          osVersion: '15.1 (24B83)',
          complianceState: 'inGracePeriod',
          lastSyncDateTime: '2026-11-12T13:15:00Z',
          isEncrypted: false,
        },
      ],
      truncated: true,
      total: 57,
    },
  },
  'users-get': {
    kind: 'success',
    command: 'entra users get',
    result: {
      id: '3f1c2a9e-5b7d-4c11-9e2a-7d8b6c5a4f30',
      displayName: 'Jane Doe',
      userPrincipalName: 'jane@contoso.com',
      accountEnabled: true,
      department: 'Finance',
      mobilePhone: '',
      createdDateTime: '2024-02-01T09:12:00Z',
      manager: { displayName: 'Bob Smith', userPrincipalName: 'bob@contoso.com' },
      licenses: ['SPE_E3', 'POWER_BI_PRO'],
      signIns: {
        lastInteractive: '2026-11-19T16:02:11Z',
        lastNonInteractive: '2026-11-20T07:01:00Z',
        lastSuccessful: '2026-11-20T07:01:00Z',
        source: 'signInActivity',
      },
      daysSinceLastSignIn: 0,
    },
  },
  'health-overview': {
    kind: 'success',
    command: 'health overview',
    result: {
      summary: '1 of 3 services has an active issue: Exchange Online (serviceDegradation)',
      degraded: [{ service: 'Exchange Online', status: 'serviceDegradation' }],
      recentlyRestored: [],
      services: [
        { service: 'Exchange Online', status: 'serviceDegradation' },
        { service: 'Microsoft Teams', status: 'serviceOperational' },
        { service: 'SharePoint Online', status: 'serviceOperational' },
      ],
    },
  },
  'empty-list': {
    kind: 'success',
    command: 'entra users list',
    result: { items: [], truncated: false },
  },
  'bitlocker-keys': {
    kind: 'success',
    command: 'intune devices bitlocker-key',
    result: {
      device: {
        id: '0b8d1c3e-8f4e-4b39-9a51-6c2f0e7d1a11',
        deviceName: 'LAPTOP-0042',
        user: 'jane@contoso.com',
        os: 'Windows 10.0.26100.2314',
        serialNumber: 'PF0042XY',
        lastSyncDateTime: '2026-11-17T10:00:00Z',
        daysSinceLastSync: 3,
        complianceState: 'noncompliant',
        managementState: 'managed',
      },
      keys: [{ id: '4c1e2d3f-5a6b-4c7d-8e9f-0a1b2c3d4e5f', createdDateTime: '2026-04-16T21:04:00Z', volumeType: '1' }],
    },
  },
  'group-members': {
    kind: 'success',
    command: 'entra groups members',
    result: {
      items: [
        {
          type: 'user',
          id: '7c2e4a10-9b3d-4f5e-8a6b-1c2d3e4f5a6b',
          displayName: 'Bob Smith',
          userPrincipalName: 'bob@contoso.com',
          accountEnabled: true,
        },
        {
          type: 'device',
          id: '2f3e4d5c-6b7a-4c8d-9e0f-1a2b3c4d5e6f',
          displayName: 'LAPTOP-0042',
          deviceId: '6d1f0a2b-3c4d-4e5f-8a9b-0c1d2e3f4a5b',
          operatingSystem: 'Windows',
        },
      ],
      truncated: false,
    },
  },
  'error-ambiguous': {
    kind: 'error',
    code: 'AMBIGUOUS',
    message: '"WS-PF3" matches 2 devices',
    hint: 'Ask the user which device they mean, then pass its id.',
    details: [
      {
        id: '1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d',
        deviceName: 'WS-PF3',
        serialNumber: 'PF3A0001',
        user: 'jane@contoso.com',
        os: 'Windows',
        lastSyncDateTime: '2026-11-19T09:00:00Z',
      },
      {
        id: '6e7f8a9b-0c1d-4e2f-9a3b-4c5d6e7f8a9b',
        deviceName: 'WS-PF3',
        serialNumber: 'PF3A0002',
        user: null,
        os: 'Windows',
        lastSyncDateTime: '2026-08-02T14:30:00Z',
      },
    ],
  },
  'error-not-found': {
    kind: 'error',
    code: 'NOT_FOUND',
    message: 'No user matches "nobody@contoso.com"',
    hint: 'Check the spelling, or search with the user list command.',
  },
  'error-forbidden': {
    kind: 'error',
    code: 'FORBIDDEN',
    message: 'Insufficient privileges to complete the operation.',
    hint: 'Sign in again with `tenantctl auth login` to consent to DeviceManagementManagedDevices.Read.All.',
    details: { needs: 'DeviceManagementManagedDevices.Read.All', role: 'Intune Administrator' },
    requestId: '7a1b2c3d-4e5f-4061-8273-9a0b1c2d3e4f',
  },
  'confirm-wipe': {
    kind: 'confirm',
    payload: {
      ok: false,
      confirmationRequired: true,
      command: 'intune devices wipe',
      preview: {
        action: "Wipe LAPTOP-0042: factory reset, erasing all data",
        targetId: '0b8d1c3e-8f4e-4b39-9a51-6c2f0e7d1a11',
        device: { deviceName: 'LAPTOP-0042', user: 'jane@contoso.com', os: 'Windows', complianceState: 'noncompliant' },
        warnings: ['The device cannot be recovered after a wipe.'],
      },
      confirm: {
        token: 'c0nf1rm-t0k3n',
        expiresAt: '2026-11-20T15:30:00.000Z',
        rerun: 'tenantctl intune devices wipe LAPTOP-0042 --confirm c0nf1rm-t0k3n',
      },
      instructions:
        'Nothing has changed yet. Show this preview to the user and get explicit approval before re-running with --confirm.',
    },
  },
};

for (const [name, fixture] of Object.entries(fixtures)) {
  let json: string;
  let text: string;
  if (fixture.kind === 'success') {
    json = output.renderSuccess(fixture.command, fixture.result, { format: 'json', fields: fixture.fields });
    text = output.renderSuccess(fixture.command, fixture.result, { format: 'table', fields: fixture.fields });
  } else if (fixture.kind === 'error') {
    const error = new errors.CliError(fixture.code, fixture.message, {
      hint: fixture.hint,
      details: fixture.details,
      requestId: fixture.requestId,
    });
    json = output.renderError(error, 'json');
    text = output.renderError(error, 'table');
  } else {
    json = output.renderConfirmation(fixture.payload, 'json');
    text = output.renderConfirmation(fixture.payload, 'table');
  }
  // A terminal trims trailing blanks from every row; the lens sees lines that way.
  const trim = (s: string) => `${s.split('\n').map((line) => line.trimEnd()).join('\n')}\n`;
  writeFileSync(join(out, `${name}.json`), trim(json));
  writeFileSync(join(out, `${name}.txt`), trim(text));
}
console.log(`gen-fixtures: ${Object.keys(fixtures).length} fixtures from ${src}`);
