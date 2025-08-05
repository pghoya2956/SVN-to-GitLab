import { test, expect } from '@playwright/test';

// 테스트용 SVN 저장소 정보
const TEST_REPOSITORIES = {
  small: {
    name: 'SVNBook Source',
    url: 'https://svn.code.sf.net/p/svnbook/source/trunk',
    expectedFiles: ['en', 'tools'],
    expectedSize: 'small' // < 100MB
  },
  medium: {
    name: 'Apache Commons Collections',
    url: 'https://svn.apache.org/repos/asf/commons/proper/collections/trunk',
    expectedFiles: ['src', 'pom.xml'],
    expectedSize: 'medium' // 100MB - 1GB
  }
};

test.describe('SVN to GitLab Migration E2E Tests', () => {
  let testEmail: string;
  let testPassword: string;
  let gitlabToken: string;

  test.beforeAll(async () => {
    // 테스트 계정 정보 (환경 변수에서 읽기)
    testEmail = process.env.TEST_USER_EMAIL || 'ghdi7662@gmail.com';
    testPassword = process.env.TEST_USER_PASSWORD || 'password123';
    gitlabToken = process.env.TEST_GITLAB_TOKEN || 'glpat-SvhybvwSBFGkKgGxVsr-';
  });

  test.beforeEach(async ({ page }) => {
    // 로그인
    await page.goto('http://localhost:3000/users/sign_in');
    await page.fill('input[name="user[email]"]', testEmail);
    await page.fill('input[name="user[password]"]', testPassword);
    await page.click('input[type="submit"]');
    
    // 로그인 성공 확인
    await expect(page).toHaveURL('http://localhost:3000/repositories');
  });

  test('시나리오 1: 소형 프로젝트 기본 마이그레이션', async ({ page }) => {
    const repo = TEST_REPOSITORIES.small;
    
    // 1. 새 저장소 추가
    await page.goto('http://localhost:3000/repositories/new');
    await page.fill('input[name="repository[name]"]', `Test ${repo.name} ${Date.now()}`);
    await page.fill('input[name="repository[svn_url]"]', repo.url);
    await page.selectOption('select[name="repository[auth_type]"]', 'basic');
    await page.fill('input[name="repository[username]"]', ''); // 공개 저장소
    await page.fill('input[name="repository[password]"]', '');
    await page.click('button:has-text("저장소 추가")');
    
    // 저장소 생성 성공 확인
    await expect(page.locator('.alert-success')).toContainText('Repository was successfully created');
    
    // 2. GitLab 프로젝트 선택
    await page.click('a:has-text("Select GitLab Project")');
    await page.waitForSelector('button:has-text("Select")');
    await page.click('button:has-text("Select"):first'); // 첫 번째 프로젝트 선택
    
    // 3. 마이그레이션 시작
    await page.click('a:has-text("Start Migration")');
    await page.click('button:has-text("Start Migration")');
    
    // Job 페이지로 이동 확인
    await expect(page).toHaveURL(/\/jobs\/\d+/);
    
    // 4. Job 진행 상황 모니터링 (최대 5분 대기)
    let jobCompleted = false;
    let jobStatus = '';
    const maxWaitTime = 5 * 60 * 1000; // 5분
    const startTime = Date.now();
    
    while (!jobCompleted && (Date.now() - startTime) < maxWaitTime) {
      await page.waitForTimeout(5000); // 5초마다 체크
      await page.reload();
      
      jobStatus = await page.locator('dd:right-of(dt:has-text("Status:")) span').textContent() || '';
      
      if (jobStatus === 'Completed' || jobStatus === 'Failed') {
        jobCompleted = true;
      }
    }
    
    // 5. 결과 검증
    expect(jobStatus).toBe('Completed');
    
    // 출력 로그 확인
    const outputLog = await page.locator('[role="tabpanel"] div').textContent();
    expect(outputLog).toContain('Pushing to GitLab');
    expect(outputLog).toContain('Migration completed successfully');
  });

  test('시나리오 2: 저장소 검증 기능', async ({ page }) => {
    const repo = TEST_REPOSITORIES.small;
    
    // 저장소 추가
    await page.goto('http://localhost:3000/repositories/new');
    await page.fill('input[name="repository[name]"]', `Validation Test ${Date.now()}`);
    await page.fill('input[name="repository[svn_url]"]', repo.url);
    await page.click('button:has-text("저장소 추가")');
    
    // 검증 버튼 클릭
    await page.click('button:has-text("저장소 검증")');
    
    // 검증 결과 대기
    await page.waitForSelector('.alert-success, .alert-danger', { timeout: 30000 });
    
    // 성공 메시지 확인
    const validationResult = await page.locator('.alert').textContent();
    expect(validationResult).toContain('검증 성공');
    expect(validationResult).toContain('HEAD 리비전');
  });

  test('시나리오 3: 잘못된 SVN URL 처리', async ({ page }) => {
    // 잘못된 URL로 저장소 추가 시도
    await page.goto('http://localhost:3000/repositories/new');
    await page.fill('input[name="repository[name]"]', 'Invalid URL Test');
    await page.fill('input[name="repository[svn_url]"]', 'https://invalid-svn-url.com/repo');
    await page.click('button:has-text("저장소 추가")');
    
    // 저장소는 생성되지만 검증 시 실패해야 함
    await page.click('button:has-text("저장소 검증")');
    await page.waitForSelector('.alert-danger', { timeout: 30000 });
    
    const errorMessage = await page.locator('.alert-danger').textContent();
    expect(errorMessage).toContain('검증 실패');
  });

  test('시나리오 4: 중복 실행 방지', async ({ page }) => {
    const repo = TEST_REPOSITORIES.small;
    
    // 저장소 생성 및 첫 번째 마이그레이션 시작
    await page.goto('http://localhost:3000/repositories/new');
    await page.fill('input[name="repository[name]"]', `Duplicate Test ${Date.now()}`);
    await page.fill('input[name="repository[svn_url]"]', repo.url);
    await page.click('button:has-text("저장소 추가")');
    
    // GitLab 프로젝트 선택
    await page.click('a:has-text("Select GitLab Project")');
    await page.click('button:has-text("Select"):first');
    
    // 첫 번째 마이그레이션 시작
    await page.click('a:has-text("Start Migration")');
    await page.click('button:has-text("Start Migration")');
    
    // Job이 실행 중인 상태에서 저장소 페이지로 돌아가기
    const jobUrl = page.url();
    const repoId = jobUrl.match(/repositories\/(\d+)/)?.[1];
    await page.goto(`http://localhost:3000/repositories/${repoId}`);
    
    // 두 번째 마이그레이션 시작 시도
    await page.click('a:has-text("Start Migration")');
    await page.click('button:has-text("Start Migration")');
    
    // 오류 메시지 확인
    await expect(page.locator('.alert-danger')).toContainText('already has an active job running');
  });

  test('시나리오 5: Job 이력 확인', async ({ page }) => {
    // 저장소 목록에서 기존 저장소 선택
    await page.goto('http://localhost:3000/repositories');
    
    if (await page.locator('table tbody tr').count() > 0) {
      await page.click('table tbody tr:first-child a:has-text("상세")');
      
      // Job History 섹션 확인
      const jobHistorySection = page.locator('h3:has-text("Job History")');
      await expect(jobHistorySection).toBeVisible();
      
      // Job이 있다면 상세 정보 확인
      const jobCards = page.locator('.card.mb-3');
      if (await jobCards.count() > 0) {
        // 첫 번째 Job 카드의 정보 확인
        const firstJob = jobCards.first();
        await expect(firstJob.locator('.card-header')).toContainText(/Migration|Incremental Sync/);
        await expect(firstJob.locator('.badge')).toBeVisible();
      }
    }
  });

  test.skip('시나리오 6: 증분 동기화 (초기 마이그레이션 완료 후)', async ({ page }) => {
    // 이 테스트는 초기 마이그레이션이 완료된 저장소가 필요함
    // 수동으로 설정하거나 이전 테스트의 결과를 사용
    
    await page.goto('http://localhost:3000/repositories');
    
    // 완료된 마이그레이션이 있는 저장소 찾기
    const rows = page.locator('table tbody tr');
    const rowCount = await rows.count();
    
    for (let i = 0; i < rowCount; i++) {
      const row = rows.nth(i);
      await row.locator('a:has-text("상세")').click();
      
      // Job History에서 완료된 마이그레이션 확인
      const completedMigration = await page.locator('.card:has-text("Migration") .badge.bg-success').count();
      
      if (completedMigration > 0) {
        // 편집 페이지로 이동
        await page.click('a:has-text("Edit this repository")');
        
        // 증분 동기화 활성화
        const incrementalSyncCheckbox = page.locator('input[name="repository[enable_incremental_sync]"]');
        if (await incrementalSyncCheckbox.isVisible()) {
          await incrementalSyncCheckbox.check();
          await page.click('button:has-text("저장소 수정")');
          
          // 증분 동기화 실행
          await page.click('a:has-text("Sync Now")');
          
          // Job 페이지로 이동 확인
          await expect(page).toHaveURL(/\/jobs\/\d+/);
          
          // Job 타입 확인
          const jobType = await page.locator('dd:right-of(dt:has-text("Type:"))').textContent();
          expect(jobType).toBe('Incremental Sync');
        }
        break;
      }
    }
  });
});

test.describe('Performance Tests', () => {
  test('메모리 사용량 모니터링', async ({ page }) => {
    // 브라우저의 Performance API를 사용하여 메모리 사용량 체크
    const metrics = await page.evaluate(() => {
      if ('memory' in performance) {
        return (performance as any).memory;
      }
      return null;
    });
    
    if (metrics) {
      console.log('Memory usage:', {
        usedJSHeapSize: `${(metrics.usedJSHeapSize / 1024 / 1024).toFixed(2)} MB`,
        totalJSHeapSize: `${(metrics.totalJSHeapSize / 1024 / 1024).toFixed(2)} MB`,
        jsHeapSizeLimit: `${(metrics.jsHeapSizeLimit / 1024 / 1024).toFixed(2)} MB`
      });
    }
  });
});

test.describe('Security Tests', () => {
  test('XSS 방지 확인', async ({ page }) => {
    await page.goto('http://localhost:3000/repositories/new');
    
    // XSS 시도
    const xssPayload = '<script>alert("XSS")</script>';
    await page.fill('input[name="repository[name]"]', xssPayload);
    await page.fill('input[name="repository[svn_url]"]', 'https://example.com');
    await page.click('button:has-text("저장소 추가")');
    
    // 스크립트가 실행되지 않고 이스케이프되어 표시되는지 확인
    const repositoryName = await page.locator('h5').first().textContent();
    expect(repositoryName).not.toContain('<script>');
    expect(repositoryName).toContain('alert'); // 텍스트로 표시됨
  });

  test('SQL Injection 방지 확인', async ({ page }) => {
    await page.goto('http://localhost:3000/repositories/new');
    
    // SQL Injection 시도
    const sqlPayload = "'; DROP TABLE repositories; --";
    await page.fill('input[name="repository[name]"]', sqlPayload);
    await page.fill('input[name="repository[svn_url]"]', 'https://example.com');
    await page.click('button:has-text("저장소 추가")');
    
    // 정상적으로 저장되고 테이블이 삭제되지 않았는지 확인
    await page.goto('http://localhost:3000/repositories');
    await expect(page.locator('table')).toBeVisible();
  });
});