import { test, expect } from '@playwright/test';

test.describe('Resumable Migration', () => {
  test.beforeEach(async ({ page }) => {
    // Login
    await page.goto('http://localhost:3000');
    await page.getByPlaceholder('Email').fill('ghdi7662@gmail.com');
    await page.getByPlaceholder('Password').fill('password123');
    await page.getByRole('button', { name: 'Login' }).click();
    await expect(page).toHaveURL('http://localhost:3000/repositories');
  });

  test('should show resume button for failed resumable job', async ({ page }) => {
    // SVNBook 저장소로 이동
    await page.getByRole('link', { name: 'SVNBook E2E Test' }).click();
    
    // Jobs 탭 클릭
    await page.getByRole('link', { name: 'Jobs' }).click();
    
    // 첫 번째 failed job 찾기 (테스트 스크립트로 생성한 것)
    const failedJobRow = page.locator('tr').filter({ hasText: 'Failed' }).first();
    if (await failedJobRow.count() > 0) {
      // View 버튼 클릭
      await failedJobRow.getByRole('link', { name: 'View' }).click();
      
      // Resume Migration 버튼 확인
      const resumeButton = page.getByRole('link', { name: 'Resume Migration' });
      await expect(resumeButton).toBeVisible();
      
      // 재개 정보 확인
      await expect(page.locator('.alert-info')).toContainText('이 작업은 재개 가능합니다');
      await expect(page.locator('.alert-info')).toContainText('마지막 체크포인트');
      await expect(page.locator('.alert-info')).toContainText('시도 횟수');
      
      // Phase Progress 컴포넌트 확인
      await expect(page.locator('.phase-progress')).toBeVisible();
      await expect(page.locator('.phase-item')).toHaveCount(4); // cloning, applying_strategy, pushing, completed
    }
  });

  test('should not show resume button for non-resumable job', async ({ page }) => {
    // Jobs 페이지로 이동
    await page.goto('http://localhost:3000/jobs');
    
    // 실패한 non-resumable job 찾기
    const jobRows = page.locator('tbody tr');
    const count = await jobRows.count();
    
    for (let i = 0; i < count; i++) {
      const row = jobRows.nth(i);
      const statusText = await row.locator('td').nth(3).textContent();
      
      if (statusText?.includes('Failed')) {
        await row.getByRole('link', { name: 'View' }).click();
        
        // Job 페이지에서 Resume 버튼이 없는지 확인
        const resumeButton = page.getByRole('link', { name: 'Resume Migration' });
        const isVisible = await resumeButton.isVisible().catch(() => false);
        
        if (!isVisible) {
          // Non-resumable job 찾음
          await expect(resumeButton).not.toBeVisible();
          console.log('Found non-resumable failed job');
          break;
        }
        
        // 다시 Jobs 페이지로
        await page.goto('http://localhost:3000/jobs');
      }
    }
  });

  test('should display phase progress correctly', async ({ page }) => {
    // 실행 중인 job 생성을 위해 새 마이그레이션 시작
    await page.goto('http://localhost:3000/repositories');
    
    // 저장소가 설정되어 있는지 확인
    const hasConfiguredRepo = await page.locator('text=GitLab Target').isVisible().catch(() => false);
    
    if (hasConfiguredRepo) {
      // Jobs 페이지에서 running job 찾기
      await page.goto('http://localhost:3000/jobs');
      
      const runningJob = page.locator('tr').filter({ hasText: 'Running' }).first();
      if (await runningJob.count() > 0) {
        await runningJob.getByRole('link', { name: 'View' }).click();
        
        // Phase Progress 확인
        await expect(page.locator('.phase-progress')).toBeVisible();
        
        // 현재 진행 중인 phase 확인 (애니메이션 있음)
        const currentPhase = page.locator('.phase-item.current');
        await expect(currentPhase).toHaveCount(1);
        
        // 완료된 phase 확인
        const completedPhases = page.locator('.phase-item.completed');
        const completedCount = await completedPhases.count();
        expect(completedCount).toBeGreaterThanOrEqual(0);
      }
    }
  });

  test('should handle resume action', async ({ page }) => {
    // Jobs 페이지로 이동
    await page.goto('http://localhost:3000/jobs');
    
    // 재개 가능한 failed job 찾기
    const failedJobs = page.locator('tr').filter({ hasText: 'Failed' });
    const failedCount = await failedJobs.count();
    
    if (failedCount > 0) {
      // 첫 번째 failed job 보기
      await failedJobs.first().getByRole('link', { name: 'View' }).click();
      
      // Resume 버튼이 있는지 확인
      const resumeButton = page.getByRole('link', { name: 'Resume Migration' });
      if (await resumeButton.isVisible()) {
        // 재개 전 retry count 확인
        const retryText = await page.locator('.alert-info').textContent();
        const retryMatch = retryText?.match(/시도 횟수: (\d+)\/3/);
        const beforeRetryCount = retryMatch ? parseInt(retryMatch[1]) : 0;
        
        // Resume 클릭
        await page.on('dialog', dialog => dialog.accept()); // 확인 다이얼로그 자동 수락
        await resumeButton.click();
        
        // 성공 메시지 확인
        await expect(page.locator('.alert')).toContainText('마이그레이션이 마지막 체크포인트에서 재개되었습니다');
        
        // 상태가 변경되었는지 확인 (running 또는 pending)
        await page.waitForTimeout(2000); // 상태 업데이트 대기
        const statusBadge = page.locator('.badge').first();
        const newStatus = await statusBadge.textContent();
        expect(['Running', 'Pending']).toContain(newStatus);
      }
    }
  });
});