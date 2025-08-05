import { test, expect } from '@playwright/test';

test.describe('SVN to GitLab Migration Integration Tests', () => {
  const baseURL = 'http://localhost:3000';
  const testEmail = `test${Date.now()}@example.com`;
  const testPassword = 'password123';

  test.beforeEach(async ({ page }) => {
    await page.goto(baseURL);
  });

  test('01: User Registration and Login', async ({ page }) => {
    // Sign up
    await page.click('text=Sign up');
    await page.fill('input[name="user[email]"]', testEmail);
    await page.fill('input[name="user[password]"]', testPassword);
    await page.fill('input[name="user[password_confirmation]"]', testPassword);
    await page.click('input[type="submit"][value="Sign up"]');
    
    // Verify successful registration
    await expect(page).toHaveURL(/repositories/);
    await expect(page.locator('text=Welcome! You have signed up successfully')).toBeVisible();
  });

  test('02: GitLab Token Configuration', async ({ page }) => {
    // Login first
    await page.click('text=Login');
    await page.fill('input[name="user[email]"]', testEmail);
    await page.fill('input[name="user[password]"]', testPassword);
    await page.click('input[type="submit"][value="Log in"]');

    // Configure GitLab token
    await page.click('text=Configure GitLab Access');
    await page.fill('input[name="gitlab_token[token]"]', 'glpat-test-token-123');
    await page.click('input[type="submit"]');
    
    // Verify token saved
    await expect(page.locator('text=GitLab token was successfully')).toBeVisible();
  });

  test('03: Repository Creation', async ({ page }) => {
    // Login
    await page.click('text=Login');
    await page.fill('input[name="user[email]"]', testEmail);
    await page.fill('input[name="user[password]"]', testPassword);
    await page.click('input[type="submit"][value="Log in"]');

    // Create repository
    await page.click('text=New Repository');
    await page.fill('input[name="repository[name]"]', 'Test Repository');
    await page.fill('input[name="repository[svn_url]"]', 'https://svn.apache.org/repos/asf/subversion/trunk');
    await page.selectOption('select[name="repository[auth_type]"]', 'none');
    await page.click('input[type="submit"]');
    
    // Verify repository created
    await expect(page.locator('h2:has-text("Test Repository")')).toBeVisible();
  });

  test('04: Migration Strategy Configuration', async ({ page }) => {
    // Login
    await page.click('text=Login');
    await page.fill('input[name="user[email]"]', testEmail);
    await page.fill('input[name="user[password]"]', testPassword);
    await page.click('input[type="submit"][value="Log in"]');

    // Navigate to repository
    await page.click('text=Test Repository');
    await page.click('text=Edit Strategy');

    // Configure migration strategy
    await page.selectOption('select[name="repository[migration_type]"]', 'standard');
    await page.check('input[name="repository[preserve_history]"]');
    await page.click('input[type="submit"]');
    
    // Verify strategy saved
    await expect(page.locator('text=Migration strategy updated')).toBeVisible();
  });

  test('05: Job Execution and Monitoring', async ({ page }) => {
    // Login
    await page.click('text=Login');
    await page.fill('input[name="user[email]"]', testEmail);
    await page.fill('input[name="user[password]"]', testPassword);
    await page.click('input[type="submit"][value="Log in"]');

    // Navigate to jobs
    await page.click('text=Jobs');
    
    // Verify job list page
    await expect(page.locator('h2:has-text("Migration Jobs")')).toBeVisible();
    
    // Check for job status elements
    await expect(page.locator('th:has-text("Status")')).toBeVisible();
    await expect(page.locator('th:has-text("Repository")')).toBeVisible();
    await expect(page.locator('th:has-text("Progress")')).toBeVisible();
  });

  test('06: Incremental Sync Configuration', async ({ page }) => {
    // This test assumes a repository with completed initial migration exists
    // Login with existing user
    await page.click('text=Login');
    await page.fill('input[name="user[email]"]', 'ghdi7662@gmail.com');
    await page.fill('input[name="user[password]"]', 'password123');
    await page.click('input[type="submit"][value="Log in"]');

    // Navigate to repository
    await page.goto(`${baseURL}/repositories/1`);
    
    // Check for incremental sync elements
    const syncButton = page.locator('text=Sync Now');
    const syncStatus = page.locator('text=Incremental Sync Status');
    
    // Verify elements exist (may or may not be visible depending on state)
    await expect(syncStatus).toBeVisible();
  });
});

test.describe('Error Handling Tests', () => {
  test('Invalid SVN URL', async ({ page }) => {
    await page.goto('http://localhost:3000');
    
    // Create account and login flow...
    // Then try to create repository with invalid URL
    await page.click('text=New Repository');
    await page.fill('input[name="repository[name]"]', 'Invalid Test');
    await page.fill('input[name="repository[svn_url]"]', 'not-a-valid-url');
    await page.click('input[type="submit"]');
    
    // Should show validation error
    await expect(page.locator('text=must be a valid SVN URL')).toBeVisible();
  });
});