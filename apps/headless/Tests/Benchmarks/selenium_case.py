import os
import subprocess
import time

from selenium import webdriver
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait

output = os.environ["BENCH_OUTPUT"]
options = webdriver.ChromeOptions()
options.binary_location = "/usr/bin/chromium"
options.add_argument("--headless=new")
options.add_argument("--window-size=1160,760")
options.add_argument("--disable-background-networking")
driver = webdriver.Chrome(options=options)
encoder = subprocess.Popen([
    "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
    "-f", "image2pipe", "-framerate", "5", "-vcodec", "png", "-i", "pipe:0",
    "-an", "-c:v", "mpeg4", "-q:v", "4", "-pix_fmt", "yuv420p",
    "-movflags", "+faststart", os.path.join(output, "flow.mp4"),
], stdin=subprocess.PIPE)

def tour():
    maximum = driver.execute_script("return Math.max(0, document.documentElement.scrollHeight - innerHeight)")
    for step in range(6):
        driver.execute_script("scrollTo(0, arguments[0])", maximum * step / 5)
        encoder.stdin.write(driver.get_screenshot_as_png())
        time.sleep(0.1)

try:
    driver.get(os.environ["BENCH_URL"])
    WebDriverWait(driver, 10).until(lambda page: page.title == "Designers Dashboard")
    tour()
    driver.find_element(By.XPATH, "//button[normalize-space()='Continue']").click()
    WebDriverWait(driver, 10).until(lambda page: "/next" in page.current_url and "Designer details" in page.find_element(By.TAG_NAME, "body").text)
    tour()
    driver.save_screenshot(os.path.join(output, "final.png"))
finally:
    encoder.stdin.close()
    encoder.wait(timeout=15)
    driver.quit()
