from fastapi import FastAPI

app = FastAPI()


@app.post('/chatkit')
async def chatkit():
    return {'status': 'ok', 'message': 'ChatKit endpoint ready'}


@app.get('/health')
async def health():
    return {'status': 'healthy'}
