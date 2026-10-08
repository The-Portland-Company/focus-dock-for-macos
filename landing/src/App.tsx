import {
  Badge,
  Box,
  Button,
  Container,
  Flex,
  HStack,
  Heading,
  IconButton,
  Image,
  Modal,
  ModalBody,
  ModalCloseButton,
  ModalContent,
  ModalHeader,
  ModalOverlay,
  SimpleGrid,
  Stack,
  Text,
  VStack,
  useClipboard,
  useColorMode,
  useDisclosure,
  Icon,
  Link,
  Tag,
} from "@chakra-ui/react";
import {
  FiCheck,
  FiCopy,
  FiDollarSign,
  FiDownload,
  FiHeart,
  FiMoon,
  FiMonitor,
  FiSun,
  FiFolder,
  FiZap,
  FiLayout,
  FiEye,
  FiGithub,
  FiLayers,
  FiSettings,
} from "react-icons/fi";
import {
  SiCashapp,
  SiPaypal,
  SiVenmo,
  SiZelle,
} from "react-icons/si";
import { FaEthereum, FaLinkedin } from "react-icons/fa";
import type { IconType } from "react-icons";
import { useState } from "react";

type TpcTheme = { get: () => string; next: () => string; set: (p: string) => void; resolve: (p: string) => string };
const tpcTheme = () => (window as unknown as { tpcTheme?: TpcTheme }).tpcTheme;

const APP_VERSION = "0.3.2";
const DMG_URL = `/FocusDock-${APP_VERSION}.dmg`;

function Nav({ onDonate }: { onDonate: () => void }) {
  const { setColorMode } = useColorMode();
  const [pref, setPref] = useState<string>(() => tpcTheme()?.get() ?? "system");
  const cycle = () => {
    const t = tpcTheme();
    if (!t) return;
    const next = t.next();
    t.set(next);
    setColorMode(t.resolve(next));
    setPref(next);
  };
  return (
    <Box
      as="nav"
      position="sticky"
      top={0}
      zIndex={10}
      backdropFilter="saturate(180%) blur(20px)"
      bg="bg"
      borderBottomWidth="1px"
      borderColor="border"
    >
      <Container maxW="6xl" py={3}>
        <Flex align="center" justify="space-between">
          <HStack spacing={2}>
            <Box
              boxSize="28px"
              borderRadius="8px"
              bgGradient="linear(135deg, accent-4, accent-1)"
            />
            <Text fontWeight={700} fontSize="lg" letterSpacing="-0.01em">
              Focus Dock
            </Text>
            <Tag size="sm" variant="subtle" ml={1} display={{ base: "none", sm: "inline-flex" }}>
              v{APP_VERSION}
            </Tag>
          </HStack>
          <HStack spacing={2}>
            <Button
              size="sm"
              variant="ghost"
              leftIcon={<FiHeart />}
              onClick={onDonate}
              display={{ base: "none", sm: "inline-flex" }}
            >
              Donate
            </Button>
            <Button
              as="a"
              href={DMG_URL}
              size="sm"
              variant="tpc"
              leftIcon={<FiDownload />}
            >
              Download
            </Button>
            <IconButton
              aria-label={`Theme: ${pref}. Switch theme`}
              title={`Theme: ${pref}`}
              size="sm"
              variant="ghost"
              onClick={cycle}
              icon={pref === "system" ? <FiMonitor /> : pref === "dark" ? <FiMoon /> : <FiSun />}
            />
          </HStack>
        </Flex>
      </Container>
    </Box>
  );
}

function Hero() {
  const subtle = "muted-fg";
  const tagBg = "muted";
  return (
    <Container maxW="6xl" pt={{ base: 16, md: 24 }} pb={{ base: 12, md: 16 }}>
      <VStack spacing={8} textAlign="center">
        <Tag bg={tagBg} px={3} py={1} borderRadius="full">
          Free • macOS 13+ • Apple Silicon &amp; Intel
        </Tag>
        <Heading
          as="h1"
          size="3xl"
          fontWeight={800}
          letterSpacing="-0.03em"
          lineHeight="1.05"
          maxW="4xl"
        >
          The dock the Mac deserves.{" "}
          <Box
            as="span"
            bgGradient="linear(135deg, accent-4, accent-1)"
            bgClip="text"
          >
            iOS-style folders, magnification, and parity.
          </Box>
        </Heading>
        <Text fontSize={{ base: "lg", md: "xl" }} color={subtle} maxW="3xl">
          Drag an app onto another, hold a second, and a folder forms —
          exactly like iOS. The one Dock feature Apple never shipped on the
          Mac. Plus crisp magnification, customizable everything, and a
          running-app view that finally matches macOS.
        </Text>
        <Stack direction={{ base: "column", sm: "row" }} spacing={3} pt={2} w={{ base: "full", sm: "auto" }}>
          <Button
            as="a"
            href={DMG_URL}
            size="lg"
            variant="tpc"
            leftIcon={<FiDownload />}
            px={8}
          >
            Download for macOS
          </Button>
          <Button
            as="a"
            href="https://github.com/The-Portland-Company/focus-dock-for-macos"
            size="lg"
            variant="ghost"
            leftIcon={<FiGithub />}
            target="_blank"
            rel="noopener"
          >
            View source
          </Button>
        </Stack>
        <Text fontSize="sm" color={subtle}>
          Open the DMG · drag <strong>Focus Dock</strong> into{" "}
          <strong>Applications</strong> · launch.
        </Text>
      </VStack>

      <Box mt={{ base: 12, md: 16 }}>
        <ScreenshotFrame src="/screenshots/hero.png" alt="Focus Dock on macOS" />
      </Box>
    </Container>
  );
}

function ScreenshotFrame({ src, alt }: { src: string; alt: string }) {
  const ring = "border";
  const shadow = "2xl";
  return (
    <Box
      borderRadius="2xl"
      overflow="hidden"
      borderWidth="1px"
      borderColor={ring}
      boxShadow={shadow}
    >
      <Image src={src} alt={alt} w="100%" display="block" />
    </Box>
  );
}

const features = [
  {
    icon: FiFolder,
    title: "Drag-and-hold folders",
    body: "Drop an app onto another, hold ~0.8 s, icons begin to wiggle and a folder forms — exactly like iOS.",
  },
  {
    icon: FiZap,
    title: "Native-style magnification",
    body: "Smooth Gaussian falloff centered on the cursor. Icons pre-rasterized at 256×256 so they stay sharp at every scale.",
  },
  {
    icon: FiLayers,
    title: "Running-app parity",
    body: "Every running regular app appears in the dock — pinned or not — matching the native macOS Dock you remember.",
  },
  {
    icon: FiEye,
    title: "Minimized-window tiles",
    body: "Minimized windows surface as thumbnails in a protected right-hand zone. Click any tile to restore.",
  },
  {
    icon: FiLayout,
    title: "Snap to any edge",
    body: "Bottom, top, left, or right. Flush with the screen edge or floating. Auto-orients its icon row.",
  },
  {
    icon: FiSettings,
    title: "Tune everything",
    body: "Icon size, spacing, padding, corner radius, border, tint, magnify amount. Reset any control with one click.",
  },
];

function Features() {
  const cardBg = "card";
  const cardBorder = "border";
  const iconBg = "muted";
  const iconColor = "primary";
  const subtle = "muted-fg";
  return (
    <Container maxW="6xl" py={{ base: 16, md: 24 }}>
      <VStack spacing={4} textAlign="center" mb={12}>
        <Heading size="xl" letterSpacing="-0.02em">
          Every detail, the way it should have been.
        </Heading>
        <Text fontSize="lg" color={subtle} maxW="2xl">
          A real replacement dock — not a launcher, not a wrapper. Replaces
          the native Dock on launch; restores it on quit.
        </Text>
      </VStack>
      <SimpleGrid columns={{ base: 1, md: 2, lg: 3 }} spacing={6}>
        {features.map((f) => (
          <Box
            key={f.title}
            bg={cardBg}
            borderWidth="1px"
            borderColor={cardBorder}
            borderRadius="xl"
            p={6}
          >
            <Flex
              boxSize="40px"
              borderRadius="lg"
              bg={iconBg}
              align="center"
              justify="center"
              mb={4}
            >
              <Icon as={f.icon} boxSize="20px" color={iconColor} />
            </Flex>
            <Heading size="md" mb={2} letterSpacing="-0.01em">
              {f.title}
            </Heading>
            <Text color={subtle}>{f.body}</Text>
          </Box>
        ))}
      </SimpleGrid>
    </Container>
  );
}

function Team() {
  const cardBg = "card";
  const cardBorder = "border";
  const subtle = "muted-fg";
  return (
    <Container maxW="4xl" py={{ base: 16, md: 24 }}>
      <VStack spacing={3} textAlign="center" mb={10}>
        <Heading size="2xl" letterSpacing="-0.02em">
          Meet the Team
        </Heading>
      </VStack>
      <Flex justify="center">
        <Box
          bg={cardBg}
          borderWidth="1px"
          borderColor={cardBorder}
          borderRadius="2xl"
          p={{ base: 6, md: 8 }}
          maxW="md"
          w="100%"
          textAlign="center"
        >
          <Flex justify="center" mb={5}>
            <Box
              boxSize={{ base: "160px", md: "180px" }}
              borderRadius="full"
              overflow="hidden"
              borderWidth="1px"
              borderColor={cardBorder}
            >
              <Image
                src="/team/spencer-hill.jpg"
                alt="Spencer Hill"
                w="100%"
                h="100%"
                objectFit="cover"
              />
            </Box>
          </Flex>
          <Heading size="lg" mb={1} letterSpacing="-0.01em">
            Spencer Hill
          </Heading>
          <Text color={subtle} mb={4}>
            Founder &amp; Lead Engineer
          </Text>
          <Text color={subtle} fontSize="sm" mb={6} textAlign="left">
            Spencer leads The Portland Company with two decades of web
            development expertise. He has evolved from pioneering web
            development to directing a full-stack team delivering iOS and
            Android applications, blockchain solutions, and AI-powered
            systems that transform business operations. Focus Dock is his
            love letter to the Mac — the dock Apple never shipped.
          </Text>
          <Button
            as="a"
            href="https://www.linkedin.com/in/spencerdennishill/"
            target="_blank"
            rel="noopener"
            leftIcon={<Icon as={FaLinkedin} />}
            variant="outline"
            w="100%"
          >
            Connect on LinkedIn
          </Button>
        </Box>
      </Flex>
    </Container>
  );
}

function Download() {
  const cardBg = "card";
  const cardBorder = "border";
  const subtle = "muted-fg";
  return (
    <Container maxW="4xl" py={{ base: 16, md: 24 }}>
      <Box
        bg={cardBg}
        borderWidth="1px"
        borderColor={cardBorder}
        borderRadius="2xl"
        p={{ base: 8, md: 12 }}
        textAlign="center"
      >
        <Heading size="xl" mb={3} letterSpacing="-0.02em">
          Try it. It's free.
        </Heading>
        <Text color={subtle} mb={8} fontSize="lg">
          One small DMG. No account, no telemetry. Quit it any time and the
          system Dock comes right back.
        </Text>
        <VStack spacing={3}>
          <Button
            as="a"
            href={DMG_URL}
            size="lg"
            variant="tpc"
            leftIcon={<FiDownload />}
            px={{ base: 6, md: 10 }}
            whiteSpace="normal"
            h="auto"
            minH={12}
            py={3}
          >
            Download Focus Dock {APP_VERSION}
          </Button>
          <Text fontSize="sm" color={subtle}>
            ~1.4 MB · macOS 13.0 or newer · Apple Silicon &amp; Intel
          </Text>
        </VStack>
      </Box>
    </Container>
  );
}

function Footer({ onDonate }: { onDonate: () => void }) {
  const subtle = "muted-fg";
  const border = "border";
  return (
    <Box borderTopWidth="1px" borderColor={border} py={10}>
      <Container maxW="6xl">
        <Flex
          direction={{ base: "column", md: "row" }}
          align="center"
          justify="space-between"
          gap={4}
        >
          <Text fontSize="sm" color={subtle}>
            ©{" "}{new Date().getFullYear()}{" "}
            <Link href="https://theportlandcompany.com" isExternal>
              The Portland Company
            </Link>
            .
          </Text>
          <HStack spacing={6} fontSize="sm" color={subtle}>
            <Link
              href="https://github.com/The-Portland-Company/focus-dock-for-macos"
              isExternal
            >
              GitHub
            </Link>
            <Link href={DMG_URL}>Download</Link>
            <Link as="button" onClick={onDonate}>
              Donate
            </Link>
          </HStack>
        </Flex>
        <Flex
          as="nav"
          aria-label="Legal"
          wrap="wrap"
          justify={{ base: "center", md: "flex-start" }}
          columnGap={6}
          mt={6}
          fontSize="sm"
          color={subtle}
        >
          <Link href="/terms/" minH="44px" display="inline-flex" alignItems="center">Terms</Link>
          <Link href="/privacy/" minH="44px" display="inline-flex" alignItems="center">Privacy Policy</Link>
          <Link href="/cookies/" minH="44px" display="inline-flex" alignItems="center">Cookie Policy</Link>
          <Link as="button" data-tpc-cookie-settings="" minH="44px" display="inline-flex" alignItems="center">
            Cookie settings
          </Link>
        </Flex>
      </Container>
    </Box>
  );
}

type PaymentMethod = {
  name: string;
  value: string;
  icon: IconType;
  iconColor?: string;
  preferred?: boolean;
  href?: string;
};

const PAYMENT_METHODS: PaymentMethod[] = [
  {
    name: "Cash",
    value: "Contact us to arrange payment",
    icon: FiDollarSign,
    preferred: true,
  },
  {
    name: "PayPal",
    value: "thespencerhill@gmail.com",
    icon: SiPaypal,
    href: "https://paypal.me/thespencerhill",
  },
  {
    name: "Venmo",
    value: "@spencerdennishill",
    icon: SiVenmo,
    href: "https://venmo.com/spencerdennishill",
  },
  {
    name: "Cash App",
    value: "$spencerdennishill",
    icon: SiCashapp,
    href: "https://cash.app/$spencerdennishill",
  },
  {
    name: "Zelle",
    value: "503-610-8759",
    icon: SiZelle,
  },
  {
    name: "MetaMask",
    value: "0xc882b4019011d6e34170485F54B3853Cbbd92f8A",
    icon: FaEthereum,
  },
];

function PaymentRow({ method }: { method: PaymentMethod }) {
  const { hasCopied, onCopy } = useClipboard(method.value);
  const rowBg = "muted";
  const rowBorder = "border";
  const subtle = "muted-fg";
  return (
    <Flex
      align="center"
      gap={4}
      p={4}
      bg={rowBg}
      borderWidth="1px"
      borderColor={rowBorder}
      borderRadius="xl"
    >
      <Flex
        flexShrink={0}
        boxSize="44px"
        borderRadius="full"
        bg="muted"
        align="center"
        justify="center"
      >
        <Icon as={method.icon} boxSize="22px" color="fg" />
      </Flex>
      <Box flex="1" minW={0}>
        <HStack spacing={2} mb={0.5}>
          <Text fontWeight={700}>{method.name}</Text>
          {method.preferred && (
            <Badge variant="subtle">
              Preferred
            </Badge>
          )}
        </HStack>
        <Text
          fontSize="sm"
          color={subtle}
          fontFamily={method.name === "MetaMask" ? "mono" : undefined}
          isTruncated
        >
          {method.href ? (
            <Link href={method.href} isExternal color="primary" textDecoration="underline">
              {method.value}
            </Link>
          ) : (
            method.value
          )}
        </Text>
      </Box>
      <IconButton
        aria-label={`Copy ${method.name}`}
        size="sm"
        variant="ghost"
        icon={hasCopied ? <FiCheck /> : <FiCopy />}
        onClick={onCopy}
      />
    </Flex>
  );
}

function DonateModal({
  isOpen,
  onClose,
}: {
  isOpen: boolean;
  onClose: () => void;
}) {
  const subtle = "muted-fg";
  return (
    <Modal isOpen={isOpen} onClose={onClose} size="lg" isCentered scrollBehavior="inside">
      <ModalOverlay />
      <ModalContent borderRadius="2xl">
        <ModalHeader>
          <HStack spacing={2}>
            <Icon as={FiHeart} color="primary" />
            <Text>Support Focus Dock</Text>
          </HStack>
        </ModalHeader>
        <ModalCloseButton />
        <ModalBody pb={6}>
          <Text color={subtle} mb={4}>
            Focus Dock is free. If it makes your Mac better, you can chip in
            through any of these:
          </Text>
          <Stack spacing={3}>
            {PAYMENT_METHODS.map((m) => (
              <PaymentRow key={m.name} method={m} />
            ))}
          </Stack>
        </ModalBody>
      </ModalContent>
    </Modal>
  );
}

export default function App() {
  const donate = useDisclosure();
  return (
    <Box>
      <Nav onDonate={donate.onOpen} />
      <Box as="main">
        <Hero />
        <Features />
        <Team />
        <Download />
      </Box>
      <Footer onDonate={donate.onOpen} />
      <DonateModal isOpen={donate.isOpen} onClose={donate.onClose} />
    </Box>
  );
}
