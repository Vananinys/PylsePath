import asyncio
import unittest
from api_security import ApiSecurityMiddleware


class LimitsTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.calls = 0
        async def app(scope, receive, send):
            self.calls += 1
            await receive()
            await send({'type':'http.response.start','status':200,'headers':[]})
            await send({'type':'http.response.body','body':b'ok'})
        self.app = app

    async def request(self, middleware, chunks=(b'{}',), headers=(), peer='test', delay=0):
        scope={'type':'http','method':'POST','path':'/api/v1/route','headers':headers,'client':(peer,1)}
        messages=[{'type':'http.request','body':chunk,'more_body':i<len(chunks)-1} for i,chunk in enumerate(chunks)]
        async def receive():
            if delay: await asyncio.sleep(delay)
            return messages.pop(0) if messages else {'type':'http.disconnect'}
        output=[]
        async def send(message): output.append(message)
        await middleware(scope,receive,send)
        return next(m['status'] for m in output if m['type']=='http.response.start')

    async def test_declared_oversize_never_reaches_app(self):
        self.assertEqual(await self.request(ApiSecurityMiddleware(self.app),headers=[(b'content-length',b'999999')]),413)
        self.assertEqual(self.calls,0)

    async def test_chunked_body_and_false_length_are_bounded(self):
        for headers in [[],[(b'content-length',b'1')]]:
            self.assertEqual(await self.request(ApiSecurityMiddleware(self.app,max_body=4),chunks=(b'123',b'456'),headers=headers),413)
        self.assertEqual(self.calls,0)

    async def test_rate_limit_cannot_be_bypassed_by_forwarded_header(self):
        m=ApiSecurityMiddleware(self.app,per_minute=1)
        self.assertEqual(await self.request(m),200)
        self.assertEqual(await self.request(m,headers=[(b'x-forwarded-for',b'other')]),429)

    async def test_expired_rate_limit_recovers(self):
        now=[0]; m=ApiSecurityMiddleware(self.app,per_minute=1,clock=lambda:now[0])
        self.assertEqual(await self.request(m),200)
        now[0]=61
        self.assertEqual(await self.request(m),200)

    async def test_tracking_memory_is_bounded(self):
        m=ApiSecurityMiddleware(self.app,max_clients=1)
        await self.request(m,peer='a')
        self.assertEqual(await self.request(m,peer='b'),503)
        self.assertEqual(len(m.clients),1)

    async def test_slow_body_releases_slot(self):
        m=ApiSecurityMiddleware(self.app,body_timeout=.01)
        self.assertEqual(await self.request(m,delay=.1),408)
        self.assertEqual(m.active,0)
        self.assertEqual(await self.request(m),200)

    async def test_concurrent_requests_are_limited(self):
        entered=asyncio.Event(); release=asyncio.Event()
        async def busy(scope,receive,send):
            entered.set(); await release.wait(); await self.app(scope,receive,send)
        m=ApiSecurityMiddleware(busy,max_concurrent=1)
        first=asyncio.create_task(self.request(m))
        await entered.wait()
        self.assertEqual(await self.request(m),503)
        release.set(); self.assertEqual(await first,200)
        self.assertEqual(m.active,0)

    async def test_reject_compressed_and_invalid_length(self):
        m=ApiSecurityMiddleware(self.app)
        self.assertEqual(await self.request(m,headers=[(b'content-encoding',b'gzip')]),415)
        self.assertEqual(await self.request(m,headers=[(b'content-length',b'-1')]),400)
