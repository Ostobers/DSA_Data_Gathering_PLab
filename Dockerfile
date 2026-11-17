FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 5000

# Listen on all interfaces so the published host port reaches Flask.
CMD ["python", "Hello.py"]
