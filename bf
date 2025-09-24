from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from fastapi.responses import JSONResponse
from selenium import webdriver
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from selenium.common.exceptions import TimeoutException, NoAlertPresentException, UnexpectedAlertPresentException
from bs4 import BeautifulSoup
import base64
import os
import time
import re
import requests
from queue import Queue, Empty
import threading
from fastapi.middleware.cors import CORSMiddleware

app = FastAPI()

# 浏览器池参数
POOL_SIZE = 10
driver_pool = Queue(maxsize=POOL_SIZE)
driver_lock = threading.Lock()
drivers = {}
driver_expiry = {}

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

class TimetableRequest(BaseModel):
    session_id: str
    username: str
    password: str
    captcha: str = None 

def close_alert_if_present(driver):
    try:
        alert = driver.switch_to.alert
        alert_text = alert.text
        alert.accept()
        return alert_text
    except NoAlertPresentException:
        return None

def get_captcha_img_direct():
    session = requests.Session()
    # 先访问登录页，拿到 cookies
    session.get("https://cas.cdp.edu.cn/lyuapServer/login?service=https://aic.cdp.edu.cn/xsgl/xs/login_CDSSO.aspx")
    # 假设验证码图片 src 是 /captcha.jpg
    img_resp = session.get("https://cas.cdp.edu.cn/lyuapServer/captcha.jpg")
    img_base64 = "data:image/jpeg;base64," + base64.b64encode(img_resp.content).decode()
    return img_base64

def create_driver():
    chrome_options = webdriver.ChromeOptions()
    chrome_options.add_argument("--headless")
    chrome_options.add_argument("--disable-blink-features=AutomationControlled")
    chrome_options.add_experimental_option("excludeSwitches", ["enable-automation"])
    chrome_options.add_experimental_option('useAutomationExtension', False)
    chrome_options.add_argument("--window-size=1920,1080")
    return webdriver.Chrome(options=chrome_options)

# 初始化 driver 池
for _ in range(POOL_SIZE):
    driver_pool.put(create_driver())

def get_driver(timeout=10):
    try:
        return driver_pool.get(timeout=timeout)
    except Empty:
        raise HTTPException(status_code=503, detail="服务器繁忙，请稍后再试")

def release_driver(driver):
    driver_pool.put(driver)

@app.get("/captcha")
async def get_captcha():
    driver = get_driver()
    try:
        t0 = time.time()
        driver.get("https://cas.cdp.edu.cn/lyuapServer/login?service=https://aic.cdp.edu.cn/xsgl/xs/login_CDSSO.aspx")
        captcha_img = WebDriverWait(driver, 15).until(
            EC.presence_of_element_located((By.CSS_SELECTOR, "img[alt='logo']"))
        )
        captcha_src = captcha_img.get_attribute('src')
        if captcha_src and captcha_src.startswith('data:image'):
            session_id = os.urandom(16).hex()
            drivers[session_id] = driver  # 绑定 session_id 和 driver
            driver_expiry[session_id] = time.time()
            # 启动定时器，4分钟后检查是否释放
            def auto_release_driver(sid):
                time.sleep(240)
                # 如果4分钟后还没被用掉，释放
                if sid in drivers:
                    print(f"session_id {sid} 超时未用，自动释放 driver")
                    try:
                        drivers[sid].quit()
                    except Exception:
                        pass
                    # 安全删除，避免 KeyError
                    drivers.pop(sid, None)
                    driver_expiry.pop(sid, None)
                    # driver_pool 不需要 put 回去，因为 quit 了
            threading.Thread(target=auto_release_driver, args=(session_id,), daemon=True).start()
            t1 = time.time()
            print(f"验证码接口耗时: {t1-t0:.2f}s")
            print(f"driver_pool size: {driver_pool.qsize()}")
            return {
                "session_id": session_id,
                "captcha_base64": captcha_src
            }
        else:
            raise HTTPException(status_code=400, detail="未能获取验证码图片")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/timetable")
async def get_timetable(req: TimetableRequest):
    driver = drivers.get(req.session_id)
    if not driver:
        raise HTTPException(status_code=400, detail="无效的 session_id")
    try:
        print("开始处理 timetable")
        # 获取验证码图片
        print("查找验证码图片")
        captcha_img = driver.find_element(By.CSS_SELECTOR, "img[alt='logo']")
        print("获取验证码 src")
        captcha_src = captcha_img.get_attribute('src')
        # 只允许手动输入验证码
        if not req.captcha:
            return {
                "need_manual_captcha": True,
                "force_refresh": False,
                "message": "请手动输入验证码"
            }
        else:
            auto_captcha = req.captcha
        # 填写账号、密码、验证码
        print("填写账号密码验证码")
        driver.find_element(By.ID, "userName").clear()
        driver.find_element(By.ID, "userName").send_keys(req.username)
        driver.find_element(By.ID, "password").clear()
        driver.find_element(By.ID, "password").send_keys(req.password)
        driver.find_element(By.ID, "captcha").clear()
        driver.find_element(By.ID, "captcha").send_keys(auto_captcha)
        print("点击登录按钮")
        driver.find_element(By.CLASS_NAME, "index-submit-36Dah").click()
        print("等待登录成功")
        try:
            WebDriverWait(driver, 10).until(
                lambda d: "ticket=" in d.current_url or "Default.aspx" in d.current_url
            )
        except Exception as e:
            print("登录失败:", e)
            return {
                "need_manual_captcha": True,
                "captcha_base64": captcha_src,
                "message": "验证码错误，请手动输入"
            }
        print("登录成功，继续后续流程")
        current_url = driver.current_url
        if "login_CDSSO.aspx?ticket=" in current_url:
            WebDriverWait(driver, 20).until(
                lambda d: "Default.aspx" in d.current_url
            )
        elif "Default.aspx" not in current_url:
            return {
                "need_manual_captcha": True,
                "captcha_base64": captcha_src,
                "message": "验证码错误，请手动输入"
            }
        # 点击周课表
        print("查找周课表按钮")
        wait = WebDriverWait(driver, 10)
        try:
            schedule_btn = wait.until(
                EC.element_to_be_clickable((By.XPATH, '//a[@title="周课表"]'))
            )
        except Exception:
            try:
                schedule_btn = wait.until(
                    EC.element_to_be_clickable((By.PARTIAL_LINK_TEXT, "周课表"))
                )
            except Exception as e2:
                raise HTTPException(status_code=400, detail="未能定位到'周课表'按钮")
        schedule_btn.click()
        # 切换到新窗口
        print("点击周课表，切换窗口")
        driver.switch_to.window(driver.window_handles[-1])
        wait.until(EC.url_contains("weekCourseTable.do"))
        # 获取所有学期和周数选项
        print("获取学期和周数选项")
        time.sleep(2)
        sem_options = driver.execute_script("return mini.get('semId').getData();")
        week_options = driver.execute_script("return mini.get('weekId').getData();")

        # 遍历所有学期，自动跳过未发布课表的学期
        print("遍历学期和周数")
        all_semesters = []
        default_semester = None
        default_week = None
        max_year = 0
        current_semester_name = None

        for sidx, sem in enumerate(sem_options):
            sem_value = sem.get('weekId') or sem.get('id') or sem.get('value') or sem.get('semId') or ''
            sem_name = sem.get('weekName') or sem.get('name') or sem.get('text') or sem.get('semName') or str(sem)
            # 提取学年年份
            match = re.search(r'(20\\d{2})-(20\\d{2})', sem_name)
            if match:
                year = int(match.group(1))
                if year > max_year:
                    max_year = year
                    current_semester_name = sem_name
            semester_weeks = []
            print(f"开始处理学期: {sem_name}")
            for widx, wopt in enumerate(week_options):
                print(f"处理第 {widx+1}/{len(week_options)} 周", flush=True)
                week_value = wopt.get('weekId') or wopt.get('id') or wopt.get('value') or wopt.get('week') or ''
                week_name = wopt.get('weekName') or wopt.get('name') or wopt.get('text') or wopt.get('week') or str(wopt)
                try:
                    driver.execute_script(f"""
                        mini.get('semId').setValue('{sem_value}');
                        mini.get('semId').setText('{sem_name}');
                        mini.get('semId').fire('valuechanged');
                        mini.get('weekId').setValue('{week_value}');
                        mini.get('weekId').setText('{week_name}');
                        mini.get('weekId').fire('valuechanged');
                    """)
                except Exception:
                    # JS 报错（如 mini is not defined），直接跳过
                    continue
                alert_text = close_alert_if_present(driver)
                if alert_text:
                    continue
                # 等待课表刷新
                try:
                    WebDriverWait(driver, 5).until(
                        EC.presence_of_element_located((By.CSS_SELECTOR, "table#table .courseInfo"))
                    )
                except Exception:
                    continue
                html = driver.page_source
                soup = BeautifulSoup(html, "html.parser")
                table = soup.find("table", {"id": "table"})
                if not table or not table.find_all("tr"):
                    print(f"第 {week_name} 周无课表，跳过")
                    continue
                header = table.find("tr")
                days = [cell.get_text(strip=True) for cell in header.find_all("td")][1:]
                week_courses = {day: [] for day in days}
                for row in table.find_all("tr")[1:]:
                    cells = row.find_all("td")
                    if not cells:
                        continue
                    period = cells[0].get_text(strip=True).replace("\n", "")
                    for i, cell in enumerate(cells[1:]):
                        content = cell.get_text(strip=True)
                        if content:
                            week_courses[days[i]].append({"period": period, "content": content})
                semester_weeks.append({
                    "week_id": week_value,
                    "week_name": week_name,
                    "courses": week_courses
                })
                # 记录默认学期和周（第一个有课表的）
                if default_semester is None and default_week is None and len(week_courses) > 0:
                    default_semester = sem_name
                    default_week = week_name
            if semester_weeks:  # 只添加有课表的学期
                all_semesters.append({
                    "sem_id": sem_value,
                    "sem_name": sem_name,
                    "weeks": semester_weeks
                })
                # 设置默认学期为当前学年
                if sem_name == current_semester_name:
                    default_semester = sem_name
                    default_week = semester_weeks[0]["week_name"]
        # 如果没找到，兜底
        if not default_semester and all_semesters:
            default_semester = all_semesters[0]["sem_name"]
            default_week = all_semesters[0]["weeks"][0]["week_name"]
        result = {
            "semesters": all_semesters,
            "default_semester": default_semester,
            "default_week": default_week
        }
        print("课表处理完成")
        return result
    except Exception as e:
        import traceback
        traceback.print_exc()  # 打印详细错误到控制台
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        driver.quit()
        drivers.pop(req.session_id, None)
        driver_expiry.pop(req.session_id, None)