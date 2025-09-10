import multiprocessing
import time

def cpu_load():
    while True:
        pass

if __name__ == "__main__":
    for _ in range(multiprocessing.cpu_count()):
        p = multiprocessing.Process(target=cpu_load)
        p.start()
    time.sleep(600)  # run for 10 minutes
