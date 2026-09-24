# 문제점
DMA에 slot을 이용해서 prefetch를 한다. 이렇게 하니까 prefetch를 키우기 힘들다.
O3를 위한 slot과 prefetch를 위한 FIFO를 분리하자. O3를 위한 slot은 작게 만들고
slot에 들어온 것을 FIFO에 저장하는 방식으로 하자.
